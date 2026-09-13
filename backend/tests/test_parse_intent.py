"""
Feature G6 — POST /api/ai/parse-intent.

The single property that matters: this endpoint can never break the demo.
Whatever happens — no API key, a dead network, a model that answers in prose
— the caller gets HTTP 200 and a shape it can safely ignore.

Run from backend/:
    .venv/bin/python -m pytest tests/test_parse_intent.py -q
"""

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.auth import get_current_user           # noqa: E402
from app.database import get_db                 # noqa: E402
from app.main import app                        # noqa: E402
from app.services import intent_llm             # noqa: E402

UNAVAILABLE_KEYS = {"amount", "recipient_query", "confidence", "transcript", "parsed_by"}


@pytest.fixture
def client():
    """A TestClient with auth and the DB stubbed out.

    Constructed WITHOUT the context manager on purpose: entering it fires the
    app's startup event, which initialises the real database and may train
    the ML model. This endpoint touches neither.
    """
    app.dependency_overrides[get_current_user] = lambda: SimpleNamespace(
        id="test-user", is_active=True, full_name="Test User"
    )
    app.dependency_overrides[get_db] = lambda: None
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.pop(get_current_user, None)
        app.dependency_overrides.pop(get_db, None)



@pytest.fixture(autouse=True)
def _pin_anthropic_branch(monkeypatch):
    """These tests stub the Anthropic client, so pin parse_intent to that
    branch. The default provider is now Gemini, which would bypass the stub
    entirely and make every assertion here vacuous."""
    monkeypatch.setattr(intent_llm, "EXPLAINER_PROVIDER", "anthropic")

@pytest.fixture(autouse=True)
def no_provider(monkeypatch):
    """Default every test to 'no LLM configured'.

    Without this the suite would hit the real API on a laptop that happens to
    export ANTHROPIC_API_KEY. Tests that want a provider override it again.
    """
    monkeypatch.setattr(intent_llm, "_get_client", lambda: None)


def _stub_client(reply=None, error=None):
    """A fake anthropic client: returns `reply` as one text block, or raises."""
    class _Messages:
        def create(self, **kwargs):
            if error is not None:
                raise error
            _Messages.last_kwargs = kwargs
            return SimpleNamespace(
                content=[SimpleNamespace(type="text", text=reply)]
            )

    return SimpleNamespace(messages=_Messages())


# ── The endpoint ──────────────────────────────────────────────────

class TestEndpoint:
    def test_no_provider_returns_unavailable_with_200(self, client):
        r = client.post("/api/ai/parse-intent",
                        json={"transcript": "ramesh ko do sau bhejo"})
        assert r.status_code == 200
        body = r.json()
        assert set(body) == UNAVAILABLE_KEYS
        assert body["parsed_by"] == "unavailable"
        assert body["amount"] is None
        assert body["recipient_query"] is None
        assert body["confidence"] == 0.0
        assert body["transcript"] == "ramesh ko do sau bhejo"

    def test_provider_error_never_500s(self, client, monkeypatch):
        monkeypatch.setattr(intent_llm, "_get_client",
                            lambda: _stub_client(error=RuntimeError("boom")))
        r = client.post("/api/ai/parse-intent", json={"transcript": "pay ramesh 200"})
        assert r.status_code == 200
        assert r.json()["parsed_by"] == "unavailable"

    def test_malformed_model_reply_degrades_to_unavailable(self, client, monkeypatch):
        monkeypatch.setattr(intent_llm, "_get_client",
                            lambda: _stub_client(reply="Sure! Here's the amount: 200 rupees."))
        r = client.post("/api/ai/parse-intent", json={"transcript": "pay ramesh 200"})
        assert r.status_code == 200
        assert r.json()["parsed_by"] == "unavailable"

    def test_good_reply_is_returned_as_llm(self, client, monkeypatch):
        monkeypatch.setattr(intent_llm, "_get_client", lambda: _stub_client(
            reply='{"amount": 200, "recipient_query": "ramesh", "confidence": 0.9}'))
        r = client.post("/api/ai/parse-intent",
                        json={"transcript": "ramesh ko do sau bhejo", "lang": "hi"})
        assert r.status_code == 200
        assert r.json() == {
            "amount": 200.0,
            "recipient_query": "ramesh",
            "confidence": 0.9,
            "transcript": "ramesh ko do sau bhejo",
            "parsed_by": "llm",
        }

    def test_missing_and_junk_bodies_never_500(self, client):
        for body in ({}, {"transcript": ""}, {"transcript": None},
                     {"transcript": 12345}, {"lang": "hi"}):
            r = client.post("/api/ai/parse-intent", json=body)
            assert r.status_code == 200, body
            assert r.json()["parsed_by"] == "unavailable", body

    def test_transcript_is_capped_at_500_chars(self, client):
        r = client.post("/api/ai/parse-intent", json={"transcript": "x" * 900})
        assert r.status_code == 200
        assert len(r.json()["transcript"]) == 500

    def test_max_tokens_and_model_wiring(self, client, monkeypatch):
        stub = _stub_client(reply='{"amount": 50, "recipient_query": "a", "confidence": 1}')
        monkeypatch.setattr(intent_llm, "_get_client", lambda: stub)
        client.post("/api/ai/parse-intent", json={"transcript": "pay a 50"})
        kwargs = type(stub.messages).last_kwargs
        assert kwargs["max_tokens"] == 200
        assert kwargs["system"] is intent_llm.SYSTEM_PROMPT


# ── The defensive parser (pure, no HTTP) ──────────────────────────

class TestParseLlmReply:
    def test_plain_json(self):
        out = intent_llm.parse_llm_reply(
            '{"amount": 250, "recipient_query": "sunita", "confidence": 0.8}')
        assert out == {"amount": 250.0, "recipient_query": "sunita", "confidence": 0.8}

    @pytest.mark.parametrize("fenced", [
        '```json\n{"amount": 200, "recipient_query": "ramesh", "confidence": 1}\n```',
        '```\n{"amount": 200, "recipient_query": "ramesh", "confidence": 1}\n```',
        '  ```JSON\n{"amount": 200, "recipient_query": "ramesh", "confidence": 1}\n```  ',
    ])
    def test_fenced_json_is_unwrapped(self, fenced):
        out = intent_llm.parse_llm_reply(fenced)
        assert out == {"amount": 200.0, "recipient_query": "ramesh", "confidence": 1.0}

    @pytest.mark.parametrize("bad", [
        "not json at all",
        '{"amount": 200,',                      # truncated
        '[{"amount": 200}]',                    # array, not object
        '"just a string"',
        "",
        "   ",
        None,
        "```json\n\n```",
    ])
    def test_malformed_returns_none(self, bad):
        assert intent_llm.parse_llm_reply(bad) is None

    @pytest.mark.parametrize("amount", [-1, -200, 0, "abc", None, True, [], {}])
    def test_bad_amounts_become_null(self, amount):
        import json
        out = intent_llm.parse_llm_reply(json.dumps(
            {"amount": amount, "recipient_query": "ramesh", "confidence": 0.9}))
        assert out is not None
        assert out["amount"] is None
        assert out["recipient_query"] == "ramesh"

    @pytest.mark.parametrize("amount", [1_000_001, 99_999_999, 1e12])
    def test_absurd_amounts_become_null(self, amount):
        out = intent_llm.parse_llm_reply(
            '{"amount": %r, "recipient_query": "ramesh", "confidence": 0.9}' % amount)
        assert out["amount"] is None

    def test_amount_at_the_cap_survives(self):
        out = intent_llm.parse_llm_reply(
            '{"amount": 1000000, "recipient_query": "x", "confidence": 0.5}')
        assert out["amount"] == 1_000_000.0

    def test_string_numbers_are_coerced(self):
        out = intent_llm.parse_llm_reply(
            '{"amount": "200", "recipient_query": "ramesh", "confidence": "0.7"}')
        assert out["amount"] == 200.0
        assert out["confidence"] == 0.7

    @pytest.mark.parametrize("raw,expected", [
        (1.5, 1.0), (99, 1.0), (-0.5, 0.0), (-40, 0.0),
        (0.42, 0.42), ("nope", 0.0), (None, 0.0), (True, 0.0),
    ])
    def test_confidence_is_clamped(self, raw, expected):
        import json
        out = intent_llm.parse_llm_reply(json.dumps(
            {"amount": 100, "recipient_query": "x", "confidence": raw}))
        assert out["confidence"] == expected

    @pytest.mark.parametrize("raw", ["", "   ", None, 42, True, [], {}])
    def test_bad_recipients_become_null(self, raw):
        import json
        out = intent_llm.parse_llm_reply(json.dumps(
            {"amount": 100, "recipient_query": raw, "confidence": 0.5}))
        assert out["recipient_query"] is None

    def test_missing_keys_default_safely(self):
        out = intent_llm.parse_llm_reply("{}")
        assert out == {"amount": None, "recipient_query": None, "confidence": 0.0}


# ── parse_intent() itself ─────────────────────────────────────────

class TestParseIntent:
    def test_no_provider(self):
        out = intent_llm.parse_intent("pay ramesh 200")
        assert out["parsed_by"] == "unavailable"
        assert out["transcript"] == "pay ramesh 200"

    def test_empty_transcript_short_circuits(self, monkeypatch):
        called = []
        monkeypatch.setattr(intent_llm, "_get_client",
                            lambda: called.append(1) or _stub_client(reply="{}"))
        out = intent_llm.parse_intent("   ")
        assert out == intent_llm.unavailable("")
        assert called == []          # never reached the provider

    def test_transcript_cap_applies_before_the_call(self, monkeypatch):
        stub = _stub_client(reply='{"amount": 1, "recipient_query": "a", "confidence": 1}')
        monkeypatch.setattr(intent_llm, "_get_client", lambda: stub)
        out = intent_llm.parse_intent("y" * 900)
        assert len(out["transcript"]) == intent_llm.MAX_TRANSCRIPT_CHARS == 500
        assert "y" * 500 in type(stub.messages).last_kwargs["messages"][0]["content"]

    def test_devanagari_survives_the_round_trip(self, monkeypatch):
        stub = _stub_client(
            reply='{"amount": 250, "recipient_query": "sunita", "confidence": 0.95}')
        monkeypatch.setattr(intent_llm, "_get_client", lambda: stub)
        out = intent_llm.parse_intent("सुनीता को ढाई सौ भेज दो", lang="hi")
        assert out["amount"] == 250.0
        assert out["transcript"] == "सुनीता को ढाई सौ भेज दो"
        assert out["parsed_by"] == "llm"

    @pytest.mark.parametrize("boom", [
        RuntimeError("network down"), TimeoutError("2s"), ValueError("bad key"),
    ])
    def test_every_exception_degrades(self, monkeypatch, boom):
        monkeypatch.setattr(intent_llm, "_get_client", lambda: _stub_client(error=boom))
        assert intent_llm.parse_intent("pay x 5")["parsed_by"] == "unavailable"


class TestGeminiBranch:
    """The default provider. parse_intent must route through gemini.generate_json
    and apply the same defensive coercion as the Anthropic branch."""

    @pytest.fixture(autouse=True)
    def _use_gemini(self, monkeypatch):
        monkeypatch.setattr(intent_llm, "EXPLAINER_PROVIDER", "gemini")

    def _stub_gemini(self, monkeypatch, result, configured=True):
        from app.services import gemini as gemini_mod
        monkeypatch.setattr(gemini_mod, "is_configured", lambda: configured)
        monkeypatch.setattr(gemini_mod, "generate_json", lambda *a, **k: result)

    def test_good_reply_is_returned_as_llm(self, monkeypatch):
        self._stub_gemini(monkeypatch, {
            "amount": 250, "recipient_query": "jyati", "confidence": 0.9,
        })
        out = intent_llm.parse_intent("jyati ko dhai sau bhejo")
        assert out["amount"] == 250.0
        assert out["recipient_query"] == "jyati"
        assert out["confidence"] == 0.9
        assert out["parsed_by"] == "llm"

    def test_no_key_degrades_to_unavailable(self, monkeypatch):
        self._stub_gemini(monkeypatch, None, configured=False)
        assert intent_llm.parse_intent("anything")["parsed_by"] == "unavailable"

    def test_call_failure_degrades_to_unavailable(self, monkeypatch):
        self._stub_gemini(monkeypatch, None)
        assert intent_llm.parse_intent("anything")["parsed_by"] == "unavailable"

    def test_absurd_amount_is_coerced_to_null(self, monkeypatch):
        self._stub_gemini(monkeypatch, {
            "amount": 10_000_000, "recipient_query": "x", "confidence": 1,
        })
        assert intent_llm.parse_intent("x")["amount"] is None

    def test_negative_amount_is_coerced_to_null(self, monkeypatch):
        self._stub_gemini(monkeypatch, {
            "amount": -5, "recipient_query": "x", "confidence": 1,
        })
        assert intent_llm.parse_intent("x")["amount"] is None

    def test_confidence_is_clamped(self, monkeypatch):
        self._stub_gemini(monkeypatch, {
            "amount": 10, "recipient_query": "x", "confidence": 7.5,
        })
        assert intent_llm.parse_intent("x")["confidence"] == 1.0

    def test_devanagari_survives_the_round_trip(self, monkeypatch):
        self._stub_gemini(monkeypatch, {
            "amount": 250, "recipient_query": "ज्योति", "confidence": 1,
        })
        out = intent_llm.parse_intent("ज्योति को ढाई सौ रुपये भेजो")
        assert out["recipient_query"] == "ज्योति"
        assert out["transcript"] == "ज्योति को ढाई सौ रुपये भेजो"

    def test_transcript_is_capped_before_the_call(self, monkeypatch):
        seen = {}
        from app.services import gemini as gemini_mod
        monkeypatch.setattr(gemini_mod, "is_configured", lambda: True)

        def capture(system, payload, **kwargs):
            seen["payload"] = payload
            return {"amount": 1, "recipient_query": "a", "confidence": 1}

        monkeypatch.setattr(gemini_mod, "generate_json", capture)
        out = intent_llm.parse_intent("y" * 900)
        assert len(out["transcript"]) == intent_llm.MAX_TRANSCRIPT_CHARS
        assert "y" * 900 not in seen["payload"]
