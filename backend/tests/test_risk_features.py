"""
Feature I2 — the risk model's feature vector, exposed to the app.

The phone runs the same GBM on-device (Feature I1) and needs the exact raw
features the server scored, so /api/user/offline-limit and /api/offline/sync
both return them, in the model's column order.

Run from backend/:
    .venv/bin/python -m pytest tests/test_risk_features.py -q
"""

import sys
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.auth import get_current_user                       # noqa: E402
from app.database import get_db                             # noqa: E402
from app.main import RISK_MODEL_ID, _current_limit_for, app  # noqa: E402
from app.services.risk_engine import compute_risk_score     # noqa: E402

FEATURE_KEYS = [
    "transaction_count",
    "avg_transaction_amount",
    "kyc_tier",
    "device_trust_score",
    "days_since_registration",
    "fraud_flags",
    "total_spent",
]


def _user(**overrides):
    base = dict(
        id="user-ashmita-0001",
        full_name="Ashmita Sharma",
        is_active=True,
        transaction_count=214,
        avg_transaction_amount=180.0,
        kyc_tier=3,
        device_trust_score=0.92,
        created_at=datetime.utcnow() - timedelta(days=400),
        fraud_flags=0,
        balance=10000.0,
        offline_limit=0.0,
    )
    base.update(overrides)
    return SimpleNamespace(**base)


class _FakeDB:
    """Enough of a Session for an empty sync. `query` is absent on purpose:
    the route's nonce cleanup is wrapped in try/except."""

    def commit(self):
        pass


@pytest.fixture
def user():
    return _user()


@pytest.fixture
def client(user):
    # No context manager: entering it fires the startup event (real DB).
    app.dependency_overrides[get_current_user] = lambda: user
    app.dependency_overrides[get_db] = lambda: _FakeDB()
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.pop(get_current_user, None)
        app.dependency_overrides.pop(get_db, None)


def test_current_limit_returns_the_scored_vector(user):
    limit, risk, features = _current_limit_for(user)
    assert list(features.keys()) == FEATURE_KEYS
    assert compute_risk_score(features)[0] == risk
    assert limit <= user.balance


def test_offline_limit_includes_features(client):
    r = client.get("/api/user/offline-limit")
    assert r.status_code == 200, r.text
    body = r.json()
    for key in ("limit", "expiry", "risk_score", "limit_signature"):
        assert key in body
    assert body["model"] == RISK_MODEL_ID == "gbm-v1"
    features = body["features"]
    assert list(features.keys()) == FEATURE_KEYS
    assert all(isinstance(v, (int, float)) and not isinstance(v, bool)
               for v in features.values())
    assert features["transaction_count"] == 214
    assert features["kyc_tier"] == 3
    assert features["days_since_registration"] == 400
    assert features["total_spent"] == pytest.approx(180.0 * 214)


def test_none_columns_become_model_defaults():
    sparse = _user(transaction_count=None, avg_transaction_amount=None,
                   kyc_tier=None, device_trust_score=None,
                   fraud_flags=None, created_at=None)
    _limit, _risk, features = _current_limit_for(sparse)
    assert features == {
        "transaction_count": 0, "avg_transaction_amount": 0.0, "kyc_tier": 1,
        "device_trust_score": 0.5, "days_since_registration": 0,
        "fraud_flags": 0, "total_spent": 0.0,
    }


def test_sync_includes_features(client):
    r = client.post("/api/offline/sync", json={"blobs": []})
    assert r.status_code == 200, r.text
    body = r.json()
    assert "new_offline_limit" in body and "limit_signature" in body
    assert list(body["features"].keys()) == FEATURE_KEYS
