"""
GenAI risk explainer routes (Feature D).

One endpoint turns the sklearn risk model's feature vector into a card the
user can read: "Your offline limit: ₹1,500 — because ... Here's how to raise it."
"""

from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import get_db
from ..models import Transaction, TransactionStatus, User
from ..services import explainer as explainer_service
from ..services.risk_engine import compute_offline_limit, compute_risk_score

router = APIRouter(prefix="/api", tags=["AI Explainer"])


def _limit_context(db: Session, user: User):
    """Gather the real feature values behind this user's limit."""
    days_since_reg = (datetime.utcnow() - user.created_at).days if user.created_at else 0
    risk_score, risk_factors = compute_risk_score({
        "transaction_count": user.transaction_count,
        "avg_transaction_amount": user.avg_transaction_amount,
        "kyc_tier": user.kyc_tier,
        "device_trust_score": user.device_trust_score,
        "days_since_registration": days_since_reg,
        "fraud_flags": user.fraud_flags,
        "total_spent": user.avg_transaction_amount * user.transaction_count,
    })
    limit = min(compute_offline_limit(risk_score), user.balance)

    pending = db.query(Transaction).filter(
        Transaction.sender_id == user.id,
        Transaction.status == TransactionStatus.PENDING_OFFLINE,
    ).count()

    last_sync = db.query(Transaction).filter(
        Transaction.sender_id == user.id,
        Transaction.synced_at.isnot(None),
    ).order_by(Transaction.synced_at.desc()).first()
    hours_since_last_sync = None
    if last_sync and last_sync.synced_at:
        hours_since_last_sync = max(
            0.0, (datetime.utcnow() - last_sync.synced_at).total_seconds() / 3600.0
        )

    features = explainer_service.build_feature_payload(
        user,
        pending_unsynced=pending,
        hours_since_last_sync=hours_since_last_sync,
        risk_factors=risk_factors,
    )
    return limit, risk_score, features


@router.get("/user/limit-explanation")
def limit_explanation(
    lang: str = Query("en", pattern="^(en|hi)$"),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Plain-language explanation of the caller's AI offline limit."""
    limit, risk_score, features = _limit_context(db, current_user)

    payload = {
        "user_id": current_user.id,
        "limit": limit,
        "risk_score": risk_score,
        "lang": lang,
        "features": features,
    }
    result, was_cached = explainer_service.explain_limit_cached(
        current_user.id, payload, lang
    )

    return {
        "headline": result["headline"],
        "body": result["body"],
        "tip": result["tip"],
        "limit": limit,
        "risk_score": risk_score,
        "lang": lang,
        "generated_by": "llm" if explainer_service.uses_llm() else "template",
        "cached": was_cached,
        "generated_at": datetime.utcnow().isoformat() + "Z",
    }
