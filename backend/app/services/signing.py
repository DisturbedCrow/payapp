"""
Canonical signing payload — the single source of truth on the server side.

The exact same string must be produced by the Flutter client in
`SecureTransactionEngine.buildCanonicalPayload` (mobile/lib/services/security/
secure_transaction_engine.dart). Any divergence and every signed blob from a
real phone is rejected, so this module exists to keep the format in one place
and to give the cross-language test vector a home.

Format (pipe-delimited on purpose — no JSON key-ordering bugs):

    {id}|{sender_id}|{receiver_id}|{amount}|{timestamp}|{nonce}

  amount     fixed 2-decimal, dot separator, no thousands separators (250.00)
  timestamp  UTC ISO-8601 exactly as Dart's DateTime.toUtc().toIso8601String()
             emits it: millisecond precision with a trailing Z
             (2026-09-13T10:00:00.000Z)

Dart's toIso8601String() prints milliseconds always, and microseconds only when
non-zero. `normalize_timestamp` accepts anything reasonable a client can send
and reduces it to that shape, so an older client that stored a local-time or
second-precision timestamp still verifies.
"""

from datetime import datetime, timezone

# Shared cross-language test vector. The Dart side asserts the identical
# string in mobile/test/canonical_payload_test.dart.
TEST_VECTOR_BLOB = {
    "id": "11111111-2222-3333-4444-555555555555",
    "sender_id": "sender-abc",
    "receiver_id": "receiver-xyz",
    "amount": 250.0,
    "timestamp": "2026-09-13T10:00:00.000Z",
    "nonce": "nonce-0001",
}
TEST_VECTOR_CANONICAL = (
    "11111111-2222-3333-4444-555555555555|sender-abc|receiver-xyz|"
    "250.00|2026-09-13T10:00:00.000Z|nonce-0001"
)


def normalize_timestamp(timestamp) -> str:
    """Reduce any client timestamp to Dart's toUtc().toIso8601String() shape."""
    if isinstance(timestamp, datetime):
        dt = timestamp
    elif isinstance(timestamp, str):
        raw = timestamp.strip()
        if not raw:
            return ""
        try:
            dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        except ValueError:
            # Unparseable — sign over exactly what the client sent so the
            # mismatch surfaces as invalid_signature rather than a 500.
            return raw
    else:
        return str(timestamp)

    if dt.tzinfo is None:
        # Naive timestamps are treated as UTC: that is what the server's own
        # datetime.utcnow() produces elsewhere in this codebase.
        dt = dt.replace(tzinfo=timezone.utc)
    dt = dt.astimezone(timezone.utc)

    if dt.microsecond % 1000 == 0:
        # Dart prints milliseconds when microseconds are zero.
        return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond:06d}Z"


def canonical_payload(blob: dict) -> str:
    """Build the canonical string the client signed."""
    return "|".join([
        str(blob.get("id", "")),
        str(blob.get("sender_id", "")),
        str(blob.get("receiver_id", "")),
        f"{float(blob.get('amount', 0)):.2f}",
        normalize_timestamp(blob.get("timestamp", "")),
        str(blob.get("nonce", "")),
    ])
