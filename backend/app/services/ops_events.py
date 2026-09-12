"""
In-memory ops event bus for the live projector dashboard (Feature E).

Single-process ring buffer + monotonic cursor. The dashboard polls
`GET /api/ops/feed?since=<cursor>` every 2 s; polling (rather than SSE or
websockets) is deliberate — it survives hostile venue Wi-Fi and Render
free-tier cold restarts without the page needing reconnect logic.

# PROD-TODO: replace the deque with a Redis stream (or an append-only
# ops_events table) so the feed survives a process restart and works across
# more than one uvicorn worker. In-memory is correct only because the demo
# runs a single process.
"""

import itertools
import threading
import time
from collections import deque
from typing import Any, Dict, List

_MAX_EVENTS = 300

_events: deque = deque(maxlen=_MAX_EVENTS)
_counter = itertools.count(1)
_lock = threading.Lock()

# Headline counters. Kept separately from the ring buffer so they keep
# counting after events age out of the 300-event window.
_stats: Dict[str, float] = {
    "settled_total_inr": 0.0,
    "blobs_synced": 0,
    "attacks_blocked": 0,
}
_active_users: set = set()

# Per-user trust snapshot powering the dashboard's AI TRUST ENGINE column.
_limits: Dict[str, Dict[str, Any]] = {}

# Event kinds that count as a blocked attack on the headline counter.
_ATTACK_KINDS = ("fraud_flag",)


def mask_user(name: str, user_id: str = "") -> str:
    """Never put an email or phone number on a projector.

    Prefers a first name; falls back to a short `user_1a2b` style handle.
    """
    if name:
        cleaned = name.strip()
        if "@" in cleaned:
            cleaned = cleaned.split("@")[0]
        first = cleaned.split()[0] if cleaned.split() else cleaned
        if first:
            return first
    if user_id:
        return f"user_{str(user_id).replace('-', '')[:4]}"
    return "unknown"


def emit(kind: str, **data) -> Dict[str, Any]:
    """Append an event to the feed and update the headline counters."""
    with _lock:
        event = {"id": next(_counter), "ts": time.time(), "kind": kind}
        event.update(data)
        _events.append(event)

        if kind == "settled":
            _stats["settled_total_inr"] += float(data.get("amount", 0) or 0)
            _stats["blobs_synced"] += 1
        elif kind == "blob_received":
            pass  # counted on settle so the number matches money that moved
        elif kind in _ATTACK_KINDS:
            _stats["attacks_blocked"] += 1

        for key in ("sender", "receiver", "user"):
            value = data.get(key)
            if value:
                _active_users.add(value)

        return event


def note_limit(user: str, limit: float, risk_score: float) -> None:
    """Record a user's current limit/risk for the Trust Engine panel."""
    with _lock:
        _limits[user] = {
            "user": user,
            "limit": float(limit),
            "risk_score": float(risk_score),
            "updated_at": time.time(),
        }


def since(cursor: int) -> List[Dict[str, Any]]:
    with _lock:
        return [e for e in _events if e["id"] > cursor]


def latest_id() -> int:
    with _lock:
        return _events[-1]["id"] if _events else 0


def stats() -> Dict[str, Any]:
    with _lock:
        return {
            "settled_total_inr": round(_stats["settled_total_inr"], 2),
            "blobs_synced": int(_stats["blobs_synced"]),
            "attacks_blocked": int(_stats["attacks_blocked"]),
            "active_users": len(_active_users),
        }


def limits() -> List[Dict[str, Any]]:
    with _lock:
        return sorted(_limits.values(), key=lambda x: -x["limit"])


def reset() -> None:
    """Clear everything. Used by tests and by the pre-demo reset endpoint."""
    global _counter
    with _lock:
        _events.clear()
        _counter = itertools.count(1)
        _stats["settled_total_inr"] = 0.0
        _stats["blobs_synced"] = 0
        _stats["attacks_blocked"] = 0
        _active_users.clear()
        _limits.clear()
