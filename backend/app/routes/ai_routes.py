"""
Feature G6 — the optional LLM garnish for voice intent parsing.

`POST /api/ai/parse-intent` takes a raw voice transcript and returns the same
shape the on-device deterministic parser produces (PayIntent). The app only
calls it when it is online AND the on-device parser's confidence < 0.6, so
this endpoint is never on the demo's critical path.

It cannot fail loudly: with no LLM provider configured — the default for the
laptop demo — it returns HTTP 200 with `parsed_by: "unavailable"`, which the
client reads as "keep the deterministic result".
"""

import logging

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..database import get_db
from ..models import User
from ..services import intent_llm

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api/ai", tags=["AI Voice Intent"])


@router.post("/parse-intent")
def parse_intent(
    payload: dict,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Body: {"transcript": "...", "lang": "hi"|"en" (optional)}.

    Always 200. A plain dict body (rather than a pydantic model) is
    deliberate: a malformed body degrades to the `unavailable` shape instead
    of returning a 422 the client would have to special-case.
    """
    try:
        raw = payload.get("transcript") if isinstance(payload, dict) else None
        lang = payload.get("lang") if isinstance(payload, dict) else None
        return intent_llm.parse_intent(raw, lang)
    except Exception as exc:  # belt and braces — parse_intent already swallows
        log.warning("parse-intent failed unexpectedly (%s)", exc)
        return intent_llm.unavailable("")
