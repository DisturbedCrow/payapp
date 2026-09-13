"""
Live ops dashboard (Feature E) — the page that runs on the projector.

Two routes:
  GET /api/ops/feed?since=<id>&token=...  JSON delta since a cursor
  GET /dashboard/live?token=...           the self-contained HTML page

The page polls the feed every 2 s. Polling rather than SSE/websockets is
deliberate: it survives hostile venue Wi-Fi and Render free-tier restarts
with no reconnect logic on the page.
"""

import os

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from ..config import (
    APP_NAME,
    DEMO_MODE,
    EXPLAINER_PROVIDER,
    OPS_DASH_TOKEN,
    SIGNATURE_ENFORCEMENT,
    VELOCITY_MAX_BLOBS,
    VELOCITY_WINDOW_MIN,
)
from ..database import get_db
from ..models import User
from ..services import explainer as explainer_service
from ..services import gnani
from ..services import ops_events as ops

router = APIRouter(tags=["Ops Dashboard"])

_STATIC_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "static")
_DASHBOARD_HTML = os.path.join(_STATIC_DIR, "ops_dashboard.html")


def _require_token(token: str):
    # Not full auth — a shared token keeps the projector page off the open
    # internet without adding a login step mid-demo.
    # PROD-TODO: replace with a real scoped operator credential.
    if token != OPS_DASH_TOKEN:
        raise HTTPException(status_code=403, detail="Invalid dashboard token")


@router.get("/api/ops/config")
def ops_config(token: str = Query("")):
    """What mode the backend is running in — read by the attack CLI."""
    _require_token(token)
    return {
        "app_name": APP_NAME,
        "demo_mode": DEMO_MODE,
        "signature_enforcement": SIGNATURE_ENFORCEMENT,
        "explainer_provider": EXPLAINER_PROVIDER,
        "explainer_active": "llm" if explainer_service.uses_llm() else "template",
        "velocity_max_blobs": VELOCITY_MAX_BLOBS,
        "velocity_window_min": VELOCITY_WINDOW_MIN,
        # Never the key itself — only whether one is configured.
        "voice_provider": "gnani" if gnani.is_configured() else "mock",
    }


@router.get("/api/ops/feed")
def ops_feed(
    since: int = Query(0, ge=0),
    token: str = Query(""),
    db: Session = Depends(get_db),
):
    _require_token(token)
    events = ops.since(since)
    cursor = events[-1]["id"] if events else max(since, ops.latest_id())

    stats = ops.stats()
    if not stats["active_users"]:
        # Before any traffic, show the seeded population so the panel is not
        # blank while the presenter is still talking.
        stats["active_users"] = db.query(User).count()

    return {
        "events": events,
        "cursor": cursor,
        "stats": stats,
        "limits": ops.limits(),
        "mode": {
            "demo_mode": DEMO_MODE,
            "signature_enforcement": SIGNATURE_ENFORCEMENT,
            "explainer": "llm" if explainer_service.uses_llm() else "template",
            "voice": "gnani" if gnani.is_configured() else "mock",
        },
    }


@router.post("/api/ops/reset")
def ops_reset(token: str = Query("")):
    """Clear the feed between rehearsal runs so the stage starts clean."""
    _require_token(token)
    ops.reset()
    return {"status": "reset"}


@router.get("/dashboard/live")
def dashboard_live(token: str = Query("")):
    _require_token(token)
    if not os.path.exists(_DASHBOARD_HTML):
        raise HTTPException(status_code=500, detail="Dashboard asset missing")
    return FileResponse(_DASHBOARD_HTML, media_type="text/html")
