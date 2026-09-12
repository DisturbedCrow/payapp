"""
ECDSA P-256 signature verification for offline payment blobs.

Verifies that each blob was signed by the device's registered private key,
which is bound to a specific user. This prevents:
  - Device spoofing (T2)
  - Signature forgery (T7)
  - Blob tampering (T9)

The canonical payload format lives in app/services/signing.py and MUST
match the Flutter client byte-for-byte:
  {id}|{sender_id}|{receiver_id}|{amount:.2f}|{timestamp_utc_iso}|{nonce}
"""

import base64
import hashlib
from datetime import datetime, timedelta
from typing import Optional, Tuple

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.asymmetric.ec import (
    ECDSA,
    EllipticCurvePublicKey,
    SECP256R1,
)
from cryptography.exceptions import InvalidSignature
from sqlalchemy.orm import Session

from ..config import SIGNATURE_ENFORCEMENT
from ..models import DeviceBinding, NonceRegistry, User
from .signing import canonical_payload


def build_canonical_payload(blob: dict) -> str:
    """Build the canonical string that was signed by the client.

    Delegates to app.services.signing so the format lives in exactly one
    place and is covered by the shared Dart/Python test vector.
    """
    return canonical_payload(blob)


def decode_public_key_from_base64(b64_key: str) -> Optional[EllipticCurvePublicKey]:
    """Decode a base64-encoded compressed EC public key (33 bytes for P-256)."""
    try:
        key_bytes = base64.b64decode(b64_key)
        if len(key_bytes) == 33:
            # Compressed point
            return ec.EllipticCurvePublicKey.from_encoded_point(SECP256R1(), key_bytes)
        elif len(key_bytes) == 65:
            # Uncompressed point
            return ec.EllipticCurvePublicKey.from_encoded_point(SECP256R1(), key_bytes)
        else:
            return None
    except Exception:
        return None


def verify_blob_signature(
    blob: dict,
    db: Session,
) -> Tuple[bool, str]:
    """
    Verify the ECDSA signature on a payment blob.

    Returns: (is_valid, reason)
    """
    signature_b64 = blob.get("device_signature", "")
    sender_public_key_b64 = blob.get("sender_public_key", "")
    sender_id = blob.get("sender_id", "")

    # Skip verification for legacy unsigned blobs (backward compatibility)
    if signature_b64 == "DEVICE_SIG_PLACEHOLDER" or not signature_b64:
        return False, "unsigned_blob"

    # Look up the registered device for this sender
    device_binding = None
    if sender_public_key_b64:
        device_binding = (
            db.query(DeviceBinding)
            .filter(
                DeviceBinding.public_key_base64 == sender_public_key_b64,
                DeviceBinding.is_active == True,
            )
            .first()
        )

    if not device_binding:
        # Try to find any active binding for this user
        device_binding = (
            db.query(DeviceBinding)
            .filter(
                DeviceBinding.user_id == sender_id,
                DeviceBinding.is_active == True,
            )
            .first()
        )

    public_key = None
    if device_binding:
        public_key = decode_public_key_from_base64(device_binding.public_key_base64)
    elif sender_public_key_b64 and SIGNATURE_ENFORCEMENT != "enforce":
        # First-time: key not yet registered. In log_only we verify against the
        # key the blob carries so an unregistered phone can still pay; in
        # enforce that would let anyone mint a key and sign as any sender, so
        # it is refused as unsigned_device.
        public_key = decode_public_key_from_base64(sender_public_key_b64)

    if public_key is None:
        # No device key has ever been registered for this sender and the blob
        # did not carry one. Feature B calls this `unsigned_device`.
        return False, "unsigned_device"

    # Build canonical payload
    canonical = build_canonical_payload(blob)
    canonical_bytes = canonical.encode("utf-8")

    # Decode DER signature
    try:
        sig_bytes = base64.b64decode(signature_b64)
    except Exception:
        return False, "invalid_signature_encoding"

    # Verify ECDSA signature
    try:
        public_key.verify(sig_bytes, canonical_bytes, ECDSA(hashes.SHA256()))
        # Update last_used_at
        if device_binding:
            device_binding.last_used_at = datetime.utcnow()
        return True, "valid"
    except InvalidSignature:
        return False, "signature_mismatch"
    except Exception as e:
        return False, f"verification_error: {str(e)}"


def check_nonce_uniqueness(
    nonce: str,
    sender_id: str,
    amount: float,
    db: Session,
) -> Tuple[bool, str]:
    """Check global nonce registry for replay attacks."""
    existing = db.query(NonceRegistry).filter(NonceRegistry.nonce == nonce).first()
    if existing:
        return False, "duplicate_nonce"

    # Register the nonce
    registry_entry = NonceRegistry(
        nonce=nonce,
        sender_id=sender_id,
        amount=amount,
        expires_at=datetime.utcnow() + timedelta(hours=72),
    )
    db.add(registry_entry)
    return True, "unique"


def validate_timestamp(timestamp_str: str) -> Tuple[bool, str]:
    """Validate that the blob timestamp is within the 72-hour sync window."""
    try:
        if timestamp_str.endswith("Z"):
            timestamp_str = timestamp_str[:-1] + "+00:00"
        blob_time = datetime.fromisoformat(timestamp_str)
        # Remove tzinfo for comparison with utcnow
        if blob_time.tzinfo:
            blob_time = blob_time.replace(tzinfo=None)
        now = datetime.utcnow()
        age = now - blob_time

        if age > timedelta(hours=72):
            return False, f"transaction_too_old ({age.total_seconds() / 3600:.1f}h)"
        if age < timedelta(minutes=-5):
            return False, "timestamp_in_future"

        return True, "valid"
    except (ValueError, TypeError):
        return False, "invalid_timestamp"


def cleanup_expired_nonces(db: Session):
    """Remove nonces older than 72 hours."""
    cutoff = datetime.utcnow() - timedelta(hours=72)
    db.query(NonceRegistry).filter(NonceRegistry.expires_at < cutoff).delete()
    db.commit()
