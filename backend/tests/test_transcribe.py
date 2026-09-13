"""
Feature H1/H4 — POST /api/ai/transcribe (Gnani Prisma STT proxy).

Nothing here touches the network or a real database: httpx.post is stubbed
for every Gnani path, and the DB dependency is a no-op fake.

Run from backend/:
    .venv/bin/python -m pytest tests/test_transcribe.py -q
"""

import io
import itertools
import json
import logging
import sys
import wave
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.auth import get_current_user                 # noqa: E402
from app.config import OPS_DASH_TOKEN                 # noqa: E402
from app.database import get_db                       # noqa: E402
from app.main import app                             # noqa: E402
from app.routes import voice_routes                   # noqa: E402
from app.services import gnani                        # noqa: E402
from app.services import ops_events as ops            # noqa: E402

SECRET = "gnani-test-key-DO-NOT-LEAK-7f3a91"
RESPONSE_KEYS = ["transcript", "provider", "lang", "latency_ms", "entities"]


def _wav(seconds: float = 0.1, rate: int = 16000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * int(rate * seconds))
    return buf.getvalue()


def _user(**overrides):
    base = dict(
        id="user-ashmita-0001",
        full_name="Ashmita Sharma",
        email="ashmita@gmail.com",
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
    """Enough of a Session for the routes under test. `query` is absent on
    purpose: the sync route's nonce cleanup is wrapped in try/except."""

    def commit(self):
        pass


class _FakeResponse:
    def __init__(self, status_code=200, body=None, raise_on_json=False):
        self.status_code = status_code
        self._body = body
        self._raise = raise_on_json

    def json(self):
        if self._raise:
            raise ValueError("not json")
        return self._body


class _Recorder:
    """Stands in for httpx.post; records kwargs and returns / raises."""

    def __init__(self, response=None, error=None):
        self.response = response
        self.error = error
        self.calls = []

    def __call__(self, url, **kwargs):
        self.calls.append((url, kwargs))
        if self.error is not None:
            raise self.error
        return self.response


@pytest.fixture(autouse=True)
def hermetic(monkeypatch):
    """No key, a fresh mock rotation, a clean ops feed, and no network."""
    monkeypatch.setattr(gnani, "GNANI_API_KEY", "")
    monkeypatch.setattr(voice_routes, "_mock_counter", itertools.count())
    network = _Recorder(error=AssertionError("unexpected network call"))
    monkeypatch.setattr(gnani.httpx, "post", network)
    ops.reset()
    yield network
    ops.reset()


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


def _post(client, audio=None, lang=None, filename="clip.wav"):
    files = {"audio_file": (filename, _wav() if audio is None else audio, "audio/wav")}
    data = {"lang": lang} if lang is not None else {}
    return client.post("/api/ai/transcribe", files=files, data=data)


def _configure(monkeypatch, response=None, error=None):
    monkeypatch.setattr(gnani, "GNANI_API_KEY", SECRET)
    recorder = _Recorder(response=response, error=error)
    monkeypatch.setattr(gnani.httpx, "post", recorder)
    return recorder


def _voice_events():
    return [e for e in ops.since(0) if e["kind"] == "voice_transcribed"]


# ── Validation & auth ─────────────────────────────────────────────

class TestValidation:
    def test_auth_required(self):
        app.dependency_overrides[get_db] = lambda: _FakeDB()
        try:
            c = TestClient(app)
            files = {"audio_file": ("clip.wav", _wav(), "audio/wav")}
            assert c.post("/api/ai/transcribe", files=files).status_code == 401
            bad = {"Authorization": "Bearer not-a-jwt"}
            assert c.post("/api/ai/transcribe", files=files, headers=bad).status_code == 401
        finally:
            app.dependency_overrides.pop(get_db, None)
        assert _voice_events() == []

    def test_missing_file(self, client):
        r = client.post("/api/ai/transcribe", data={"lang": "hi-IN"})
        assert r.status_code in (400, 422)

    def test_empty_file(self, client):
        r = _post(client, audio=b"")
        assert r.status_code in (400, 422)

    def test_oversized_file(self, client, monkeypatch):
        _configure(monkeypatch, response=_FakeResponse(200, {"success": True, "transcript": "x"}))
        r = _post(client, audio=b"\x00" * (voice_routes.MAX_AUDIO_BYTES + 1))
        assert r.status_code == 400
        assert gnani.httpx.post.calls == []

    def test_file_at_the_limit_is_accepted(self, client):
        r = _post(client, audio=b"\x00" * voice_routes.MAX_AUDIO_BYTES)
        assert r.status_code == 200

    @pytest.mark.parametrize("lang", ["xx-YY", "hi", "HI-IN", "en-US", "fr-FR"])
    def test_bad_lang(self, client, monkeypatch, lang):
        recorder = _configure(monkeypatch, response=_FakeResponse(200, {"success": True, "transcript": "x"}))
        r = _post(client, lang=lang)
        assert r.status_code == 400
        assert recorder.calls == []


# ── Mock mode (no key) ────────────────────────────────────────────

class TestMock:
    def test_rotation_in_order_with_amounts(self, client, hermetic):
        expected = [
            ("ramesh ko 200 rupaye bhejo", 200.0),
            ("jyati ko ₹250 bhejo", 250.0),
            ("send ₹1,500 to ramesh", 1500.0),
            ("ramesh ko 200 rupaye bhejo", 200.0),  # wraps around
        ]
        for transcript, amount in expected:
            r = _post(client)
            assert r.status_code == 200, r.text
            body = r.json()
            assert list(body.keys()) == RESPONSE_KEYS
            assert body["transcript"] == transcript
            assert body["provider"] == "mock"
            assert body["lang"] == "hi-IN"
            assert isinstance(body["latency_ms"], int) and body["latency_ms"] >= 0
            assert body["entities"] == {"amount": amount}
        assert hermetic.calls == []

    def test_lang_is_echoed(self, client):
        assert _post(client, lang="en-IN").json()["lang"] == "en-IN"

    def test_emits_ops_event(self, client):
        _post(client)
        events = _voice_events()
        assert len(events) == 1
        e = events[0]
        assert e["provider"] == "mock"
        assert e["lang"] == "hi-IN"
        assert e["ok"] is True
        assert isinstance(e["latency_ms"], int)
        assert e["user"] == "Ashmita"           # masked, never the email
        assert "ashmita@gmail.com" not in json.dumps(events)
        assert "transcript" not in e


# ── Gnani live path (httpx stubbed) ───────────────────────────────

class TestGnani:
    def test_success_sends_the_documented_request(self, client, monkeypatch, caplog):
        caplog.set_level(logging.DEBUG)
        recorder = _configure(monkeypatch, response=_FakeResponse(200, {
            "success": True,
            "request_id": "req-123",
            "timestamp": "2026-09-13T10:00:00Z",
            "transcript": "ramesh ko ₹1,50,000 bhejo",
        }))

        r = _post(client, lang="ta-IN", filename="voice.wav")
        assert r.status_code == 200, r.text
        body = r.json()
        assert list(body.keys()) == RESPONSE_KEYS
        assert body["transcript"] == "ramesh ko ₹1,50,000 bhejo"
        assert body["provider"] == "gnani"
        assert body["lang"] == "ta-IN"
        assert body["entities"] == {"amount": 150000.0}

        assert len(recorder.calls) == 1
        url, kwargs = recorder.calls[0]
        assert url == gnani.GNANI_STT_URL == "https://api.vachana.ai/stt/v3"
        assert kwargs["headers"]["X-API-Key-ID"] == SECRET
        assert kwargs["data"] == {
            "language_code": "ta-IN",
            "format": "transcribe",
            "itn_native_numerals": "false",
        }
        assert "preferred_language" not in kwargs["data"]
        name, audio, content_type = kwargs["files"]["audio_file"]
        assert name == "voice.wav" and audio == _wav() and content_type == "audio/wav"
        assert kwargs["timeout"] > 0

        # And it really encodes as the multipart form Gnani documents.
        encoded = httpx.Request("POST", url, headers=kwargs["headers"],
                                data=kwargs["data"], files=kwargs["files"])
        raw = encoded.read()
        assert encoded.headers["content-type"].startswith("multipart/form-data")
        assert b'name="format"\r\n\r\ntranscribe\r\n' in raw
        assert b'name="itn_native_numerals"\r\n\r\nfalse\r\n' in raw
        assert b'name="language_code"\r\n\r\nta-IN\r\n' in raw
        assert b'name="audio_file"; filename="voice.wav"' in raw

        assert SECRET not in r.text
        e = _voice_events()[-1]
        assert e["provider"] == "gnani" and e["ok"] is True and e["lang"] == "ta-IN"
        assert SECRET not in json.dumps(ops.since(0))
        assert SECRET not in caplog.text

    def test_default_lang_comes_from_config(self, client, monkeypatch):
        recorder = _configure(monkeypatch, response=_FakeResponse(200, {
            "success": True, "transcript": "jyati ko ₹250 bhejo"}))
        assert _post(client).status_code == 200
        assert recorder.calls[0][1]["data"]["language_code"] == "hi-IN"

    @pytest.mark.parametrize("response,error,reason", [
        (None, httpx.ReadTimeout("timed out"), "timeout"),
        (None, httpx.ConnectError("boom https://api.vachana.ai/stt/v3"), "transport_error"),
        (_FakeResponse(403, {"success": False, "error": {
            "type": "forbidden", "message": "invalid key"}}), None, "http_403"),
        (_FakeResponse(429, {"success": False, "error": {"type": "rate_limited"}}), None, "http_429"),
        (_FakeResponse(500, raise_on_json=True), None, "http_500"),
        (_FakeResponse(200, {"success": False, "error": {
            "type": "bad_audio", "message": "unreadable"}}), None, "provider_error"),
        (_FakeResponse(200, {"success": True, "transcript": ""}), None, "no_transcript"),
        (_FakeResponse(200, {"success": True}), None, "no_transcript"),
        (_FakeResponse(200, raise_on_json=True), None, "transport_error"),
    ])
    def test_failure_is_503_fallback(self, client, monkeypatch, caplog,
                                     response, error, reason):
        caplog.set_level(logging.DEBUG)
        _configure(monkeypatch, response=response, error=error)

        r = _post(client)
        assert r.status_code == 503
        assert r.json() == {"fallback": True, "provider": "gnani", "reason": reason}
        assert SECRET not in r.text

        events = _voice_events()
        assert len(events) == 1
        assert events[0]["ok"] is False and events[0]["provider"] == "gnani"
        assert isinstance(events[0]["latency_ms"], int)
        assert SECRET not in json.dumps(ops.since(0))
        assert SECRET not in caplog.text

    def test_route_503_when_service_returns_none(self, client, monkeypatch):
        monkeypatch.setattr(gnani, "GNANI_API_KEY", SECRET)
        monkeypatch.setattr(gnani, "transcribe", lambda *a, **k: None)
        r = _post(client)
        assert r.status_code == 503
        body = r.json()
        assert body["fallback"] is True and body["provider"] == "gnani"
        assert isinstance(body["reason"], str) and body["reason"]


class TestService:
    def test_transcribe_never_raises_without_key(self):
        assert gnani.transcribe(_wav(), "a.wav", "hi-IN") is None
        assert gnani.last_failure_reason() == "not_configured"

    def test_transcribe_returns_transcript(self, monkeypatch):
        _configure(monkeypatch, response=_FakeResponse(200, {
            "success": True, "request_id": "r1", "transcript": " send ₹1,500 to ramesh "}))
        assert gnani.transcribe(_wav(), "a.wav", "en-IN") == {
            "transcript": "send ₹1,500 to ramesh", "request_id": "r1"}

    def test_is_configured(self, monkeypatch):
        assert gnani.is_configured() is False
        monkeypatch.setattr(gnani, "GNANI_API_KEY", SECRET)
        assert gnani.is_configured() is True


# ── extract_amount ────────────────────────────────────────────────

@pytest.mark.parametrize("text,expected", [
    ("₹250", 250.0),
    ("jyati ko ₹250 bhejo", 250.0),
    ("send ₹1,500 to ramesh", 1500.0),
    ("₹ 1,500", 1500.0),
    ("ramesh ko ₹1,50,000 bhejo", 150000.0),
    ("₹3.50", 3.5),
    ("pay ₹250.", 250.0),
    ("Rs 250", 250.0),
    ("rs. 99 bhejo", 99.0),
    ("INR 400", 400.0),
    ("ramesh ko 200 rupaye bhejo", 200.0),
    ("250 rupees to jyati", 250.0),
    ("1 rupee", 1.0),
    ("₹२५०", 250.0),
    ("रमेश को ₹१,५०,००० भेजो", 150000.0),
    ("२५० रुपये भेजो", 250.0),
    ("₹250 aur ₹100", 250.0),
    ("ramesh ko paise bhejo", None),
    ("ramesh ko 200 bhejo", None),
    ("call 9876543210", None),
    ("₹0", None),
    ("", None),
    (None, None),
])
def test_extract_amount(text, expected):
    assert gnani.extract_amount(text) == expected


# ── Ops config ────────────────────────────────────────────────────

class TestOpsConfig:
    def test_voice_provider_mock_without_key(self):
        r = TestClient(app).get("/api/ops/config", params={"token": OPS_DASH_TOKEN})
        assert r.status_code == 200
        assert r.json()["voice_provider"] == "mock"

    def test_voice_provider_gnani_with_key_and_no_leak(self, monkeypatch):
        monkeypatch.setattr(gnani, "GNANI_API_KEY", SECRET)
        r = TestClient(app).get("/api/ops/config", params={"token": OPS_DASH_TOKEN})
        assert r.json()["voice_provider"] == "gnani"
        assert SECRET not in r.text
