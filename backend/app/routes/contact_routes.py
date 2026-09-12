"""
Recipient lookup for voice payments (Feature G, online garnish).

The deterministic parser resolves "ramesh" offline against the app's local
contact map; when the phone is online it can also ask the server, which makes
voice work against any database, not just the seeded demo cast.
"""

from fastapi import APIRouter, Depends, Query
from sqlalchemy import or_
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import get_db
from ..models import User

router = APIRouter(prefix="/api/contacts", tags=["Contacts"])


@router.get("")
def search_contacts(
    q: str = Query("", max_length=64),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Case-insensitive prefix/substring match on name or e-mail handle."""
    needle = q.strip().lower()
    query = db.query(User).filter(User.id != current_user.id, User.is_active == True)  # noqa: E712
    if needle:
        query = query.filter(or_(
            User.full_name.ilike(f"%{needle}%"),
            User.email.ilike(f"{needle}%"),
        ))
    rows = query.order_by(User.full_name).limit(10).all()
    return {
        "contacts": [
            {
                "id": u.id,
                "name": u.full_name,
                "handle": u.email.split("@")[0],
                "role": u.role.value,
            }
            for u in rows
        ]
    }
