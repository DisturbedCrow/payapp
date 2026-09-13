"""
Feature E — the ops feed contract the projector dashboard depends on.

No network and no real database: the DB dependency is a fake that reports an
empty user table.

Run from backend/:
    .venv/bin/python -m pytest tests/test_ops_dashboard.py -q
"""

import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.config import OPS_DASH_TOKEN                 # noqa: E402
from app.database import get_db                       # noqa: E402
from app.main import app                             # noqa: E402
from app.services import ops_events as ops            # noqa: E402


class _FakeQuery:
    def count(self):
        return 0


class _FakeDB:
    def query(self, *_args, **_kwargs):
        return _FakeQuery()


@pytest.fixture
def client():
    app.dependency_overrides[get_db] = lambda: _FakeDB()
    ops.reset()
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.pop(get_db, None)
        ops.reset()


def _feed(client, since=0, token=OPS_DASH_TOKEN):
    return client.get("/api/ops/feed", params={"since": since, "token": token})


def test_feed_requires_the_dashboard_token(client):
    assert _feed(client, token="not-the-token").status_code == 403


def test_epoch_is_stable_between_polls(client):
    ops.emit("settled", blob_id="b1", amount=10)
    assert _feed(client).json()["epoch"] == _feed(client, since=1).json()["epoch"]


def test_epoch_changes_on_reset_so_a_stale_cursor_can_recover(client):
    for i in range(5):
        ops.emit("settled", blob_id=f"b{i}", amount=10)
    first = _feed(client).json()
    assert first["cursor"] == 5
    assert first["epoch"]

    # A restarted process (or a reset) numbers events from 1 again.
    ops.reset()
    ops.emit("settled", blob_id="after-restart", amount=10)

    stale = _feed(client, since=first["cursor"]).json()
    # The old cursor alone would wait silently for event 6; the new epoch is
    # how the page knows to re-read from zero.
    assert stale["events"] == []
    assert stale["epoch"] != first["epoch"]

    fresh = _feed(client, since=0).json()
    assert [e["blob_id"] for e in fresh["events"]] == ["after-restart"]


def test_limits_carry_only_non_monetary_trust_signals(client):
    features = {
        "transaction_count": 12,
        "avg_transaction_amount": 450.0,
        "kyc_tier": 2,
        "device_trust_score": 0.9,
        "days_since_registration": 40,
        "fraud_flags": 0,
        "total_spent": 5400.0,
    }
    ops.note_limit("Asha", 3000, 0.25, features)
    # A later snapshot without features keeps the last copy.
    ops.note_limit("Asha", 1500, 0.45)

    (row,) = _feed(client).json()["limits"]
    assert row["limit"] == 1500
    assert row["risk_score"] == 0.45
    assert row["features"] == {
        "kyc_tier": 2,
        "transaction_count": 12,
        "days_since_registration": 40,
        "device_trust_score": 0.9,
        "fraud_flags": 0,
    }


def test_dashboard_page_is_served_uncached_without_a_token(client):
    response = client.get("/dashboard/live")
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    assert "text/html" in response.headers["content-type"]
    # The shell holds no data; everything comes from the gated feed.
    assert "/api/ops/feed" in response.text
