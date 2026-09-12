import base64

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from ..database import get_db
from ..models import User, UserRole
from ..schemas import UserCreate, UserLogin, AuthResponse, UserResponse
from ..auth import hash_password, verify_password, create_access_token, get_current_user

router = APIRouter(prefix="/api/auth", tags=["Authentication"])


@router.post("/register", response_model=AuthResponse)
def register(user_data: UserCreate, db: Session = Depends(get_db)):
    # Check if email already exists
    existing = db.query(User).filter(User.email == user_data.email).first()
    if existing:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Email already registered",
        )

    # Check if phone already exists
    if user_data.phone:
        existing_phone = db.query(User).filter(User.phone == user_data.phone).first()
        if existing_phone:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Phone number already registered",
            )

    # Create user
    role = UserRole.MERCHANT if user_data.role == "merchant" else UserRole.USER
    user = User(
        email=user_data.email,
        password_hash=hash_password(user_data.password),
        full_name=user_data.full_name,
        phone=user_data.phone,
        role=role,
        balance=10000.0 if role == UserRole.USER else 0.0,
        kyc_tier=1,
        device_trust_score=0.5,
    )
    db.add(user)
    db.commit()
    db.refresh(user)

    # Generate access token
    access_token = create_access_token(data={"sub": user.id})

    return AuthResponse(
        access_token=access_token,
        user=UserResponse(
            id=user.id,
            email=user.email,
            full_name=user.full_name,
            phone=user.phone,
            role=user.role.value,
            kyc_tier=user.kyc_tier,
            balance=user.balance,
            offline_limit=user.offline_limit,
            offline_limit_used=user.offline_limit_used,
            device_trust_score=user.device_trust_score,
            is_active=user.is_active,
            created_at=user.created_at,
        ),
    )


@router.post("/login", response_model=AuthResponse)
def login(credentials: UserLogin, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == credentials.email).first()
    if not user or not verify_password(credentials.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid email or password",
        )

    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Account is deactivated",
        )

    access_token = create_access_token(data={"sub": user.id})

    return AuthResponse(
        access_token=access_token,
        user=UserResponse(
            id=user.id,
            email=user.email,
            full_name=user.full_name,
            phone=user.phone,
            role=user.role.value,
            kyc_tier=user.kyc_tier,
            balance=user.balance,
            offline_limit=user.offline_limit,
            offline_limit_used=user.offline_limit_used,
            device_trust_score=user.device_trust_score,
            is_active=user.is_active,
            created_at=user.created_at,
        ),
    )


@router.get("/me", response_model=UserResponse)
def get_me(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    return UserResponse(
        id=current_user.id,
        email=current_user.email,
        full_name=current_user.full_name,
        phone=current_user.phone,
        role=current_user.role.value,
        kyc_tier=current_user.kyc_tier,
        balance=current_user.balance,
        offline_limit=current_user.offline_limit,
        offline_limit_used=current_user.offline_limit_used,
        device_trust_score=current_user.device_trust_score,
        is_active=current_user.is_active,
        created_at=current_user.created_at,
    )


@router.post("/device-key")
def register_device_key(
    payload: dict,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """
    Register this device's Ed25519 public key (Feature B).

    The key is the trust root for offline blobs: at sync the backend rebuilds
    the v1 canonical payload and verifies the blob's signature against the key
    stored here. Re-registering overwrites — a user has one signing device, and
    a fresh install legitimately generates a fresh key.

    PROD-TODO: overwriting silently means a stolen session can re-point the
    trust root. Production should require re-auth (or a second factor) to
    rotate a device key, and keep the old key active for a grace period so
    blobs already in flight still settle.
    """
    key_b64 = (payload or {}).get("public_key_b64", "")
    if not isinstance(key_b64, str) or not key_b64:
        raise HTTPException(status_code=400, detail="public_key_b64 required")

    try:
        raw = base64.b64decode(key_b64, validate=True)
    except Exception:
        raise HTTPException(status_code=400, detail="public_key_b64 is not valid base64")
    if len(raw) != 32:
        raise HTTPException(
            status_code=400,
            detail=f"Ed25519 public keys are 32 bytes, got {len(raw)}",
        )

    rotated = (
        current_user.device_public_key_b64 is not None
        and current_user.device_public_key_b64 != key_b64
    )
    current_user.device_public_key_b64 = key_b64
    db.commit()

    try:
        from ..services import ops_events as ops
        ops.emit(
            "device_key_registered",
            user=ops.mask_user(current_user.full_name, current_user.id),
            rotated=rotated,
        )
    except Exception:
        pass

    return {
        "status": "rotated" if rotated else "registered",
        "public_key_b64": key_b64,
    }


@router.get("/device-key")
def get_device_key(current_user: User = Depends(get_current_user)):
    """Lets the app confirm the server still holds its key (self-heal check)."""
    return {
        "registered": current_user.device_public_key_b64 is not None,
        "public_key_b64": current_user.device_public_key_b64,
    }
