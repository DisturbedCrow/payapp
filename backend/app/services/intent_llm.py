"""
Feature G6 — the "LLM garnish" for voice payment intent parsing.

The deterministic parser in `mobile/lib/services/voice_intent_parser.dart` is
the demo path: it is pure Dart, runs offline, and is the ONLY thing the stage
demo depends on. This module is the optional online garnish that the app may
consult when — and only when — that parser is unsure (confidence < 0.6).

Everything here is therefore built to fail silently:

  * no provider configured  -> the `unavailable` shape, HTTP 200
  * API error / timeout     -> the `unavailable` shape, logged at WARNING
  * malformed model reply   -> the `unavailable` shape

`unavailable` means "keep whatever the deterministic parser produced", so a
dead network, a missing API key or a hallucinating model all degrade to
exactly the behaviour the app has without this feature at all.

Provider wiring deliberately mirrors `explainer.py` (Feature D): the same
EXPLAINER_PROVIDER / ANTHROPIC_API_KEY / ANTHROPIC_MODEL /
EXPLAINER_TIMEOUT_SECONDS flags, the same lazy `import anthropic`, the same
`max_retries=0`, and the same `_strip_fences()` before `json.loads`.
"""

import json
import logging
import threading
from typing import Any, Dict, Optional

from ..config import (
    ANTHROPIC_API_KEY,
    ANTHROPIC_MODEL,
    EXPLAINER_PROVIDER,
    EXPLAINER_TIMEOUT_SECONDS,
)
from .explainer import _strip_fences

log = logging.getLogger(__name__)

# A transcript is one spoken sentence. Anything longer is either a runaway
# recogniser or someone probing the endpoint; truncate rather than reject so
# the caller still gets a well-formed answer.
MAX_TRANSCRIPT_CHARS = 500

# Above this a "parsed" amount is certainly a hallucination or a mis-heard
# digit string, never a real UPI payment on a phone with a ₹5,000 limit.
MAX_AMOUNT = 1_000_000.0

MAX_TOKENS = 200


SYSTEM_PROMPT = """You extract payment intent from a single spoken utterance in an Indian payments app. The speech may be Devanagari Hindi, Roman-script Hinglish, English, or a mix of all three in one sentence.

Return ONLY a JSON object with exactly these three keys:
{"amount": number|null, "recipient_query": string|null, "confidence": number}

Rules:
1. "amount" is the rupee amount that was actually SPOKEN. Never invent, guess, round or default an amount. If no amount is spoken, "amount" MUST be null.
2. Hindi number words compose multiplicatively and additively. "do sau" / "दो सौ" = 200. "dhai sau" / "ढाई सौ" = 250. "sava sau" = 125. "dedh sau" = 150. "do hazaar" / "दो हज़ार" = 2000. "paanch sau pachas" = 550. "das hazaar" = 10000. Digits spoken as digits ("200 rupaye") are that number.
3. "recipient_query" is the payee's name exactly as spoken, and nothing else: no postposition ("ko", "को", "to"), no verb ("bhejo", "भेजो", "send", "pay"), no currency word ("rupaye", "रुपये"), no honorific added by you. Transliterate Devanagari names to lowercase Roman script (रमेश -> "ramesh"). If no name is spoken, "recipient_query" MUST be null.
4. "confidence" is a number from 0 to 1: how sure you are that this is a payment instruction AND that both fields above are right. Use 1.0 only when amount, payee and a pay/send verb are all unambiguous. Use a low value when the utterance is not about paying anyone.
5. Output raw JSON only. No markdown, no code fences, no prose, no explanation before or after.

Examples:
"ramesh ko do sau rupaye bhejo" -> {"amount": 200, "recipient_query": "ramesh", "confidence": 1.0}
"सुनीता को ढाई सौ भेज दो" -> {"amount": 250, "recipient_query": "sunita", "confidence": 0.95}
"pay vivek" -> {"amount": null, "recipient_query": "vivek", "confidence": 0.5}
"aaj mausam accha hai" -> {"amount": null, "recipient_query": null, "confidence": 0.0}"""


def unavailable(transcript: str = "") -> Dict[str, Any]:
    """The one shape every failure path returns. The client reads this as
    'keep the deterministic result' — it is never an error."""
    return {
        "amount": None,
        "recipient_query": None,
        "confidence": 0.0,
        "transcript": transcript,
        "parsed_by": "unavailable",
    }


# ── Provider ──────────────────────────────────────────────────────

_client: Any = None
_client_ready = False
_client_lock = threading.Lock()


def _get_client():
    """The Anthropic client, or None when the LLM garnish is switched off.

    Built once, lazily, exactly like `get_explainer()`. Returns None (never
    raises) when the package is missing, the provider is 'mock', or no key is
    configured — all of which are normal, demo-safe states.
    """
    global _client, _client_ready
    if _client_ready:
        return _client
    with _client_lock:
        if _client_ready:
            return _client
        client = None
        if EXPLAINER_PROVIDER == "anthropic" and ANTHROPIC_API_KEY:
            try:
                import anthropic  # imported lazily so the package stays optional
                client = anthropic.Anthropic(
                    api_key=ANTHROPIC_API_KEY,
                    timeout=EXPLAINER_TIMEOUT_SECONDS,
                    max_retries=0,  # a retry would blow the 2 s budget
                )
            except Exception as exc:  # pragma: no cover - depends on env
                log.warning("Intent LLM unavailable: %s", exc)
                client = None
        _client = client
        _client_ready = True
        return _client


def uses_llm() -> bool:
    """True when a real provider is wired up. Used by the route for logging
    and by tests; never gates correctness."""
    return _get_client() is not None


# ── Defensive parsing ─────────────────────────────────────────────

def _coerce_amount(raw: Any) -> Optional[float]:
    """A spoken rupee amount, or None. Rejects negatives, zero, NaN/inf,
    absurd values and anything non-numeric."""
    if raw is None or isinstance(raw, bool):
        return None
    try:
        amount = float(raw)
    except (TypeError, ValueError):
        return None
    if amount != amount or amount in (float("inf"), float("-inf")):
        return None
    if amount <= 0 or amount > MAX_AMOUNT:
        return None
    return round(amount, 2)


def _coerce_recipient(raw: Any) -> Optional[str]:
    if raw is None or isinstance(raw, bool) or not isinstance(raw, str):
        return None
    name = raw.strip()
    if not name:
        return None
    return name[:80]


def _coerce_confidence(raw: Any) -> float:
    """Clamped to 0..1. Anything unparseable is 0.0 — 'no opinion'."""
    if raw is None or isinstance(raw, bool):
        return 0.0
    try:
        confidence = float(raw)
    except (TypeError, ValueError):
        return 0.0
    if confidence != confidence:  # NaN
        return 0.0
    return max(0.0, min(1.0, confidence))


def parse_llm_reply(text: str) -> Optional[Dict[str, Any]]:
    """Turn a raw model reply into {amount, recipient_query, confidence}.

    Pure and total: fenced JSON is unwrapped, and ANY malformed reply
    (prose, truncated JSON, a JSON array, wrong types) returns None rather
    than raising. A negative or absurd amount becomes a null amount — the
    reply is still usable for the recipient, it just carries no number.
    """
    try:
        if not isinstance(text, str) or not text.strip():
            return None
        parsed = json.loads(_strip_fences(text))
        if not isinstance(parsed, dict):
            return None
        return {
            "amount": _coerce_amount(parsed.get("amount")),
            "recipient_query": _coerce_recipient(parsed.get("recipient_query")),
            "confidence": _coerce_confidence(parsed.get("confidence")),
        }
    except Exception:
        return None


def clean_transcript(raw: Any) -> str:
    """Server-side cap. Whatever comes back out of here is what we echo."""
    if not isinstance(raw, str):
        return ""
    return raw.strip()[:MAX_TRANSCRIPT_CHARS]


# ── Entry point ───────────────────────────────────────────────────

def parse_intent(transcript: Any, lang: Optional[str] = None) -> Dict[str, Any]:
    """Best-effort LLM parse of one voice utterance.

    NEVER raises. Every failure — no provider, empty transcript, API error,
    timeout, malformed reply — returns the `unavailable` shape, which the
    client treats as "keep the deterministic parse".
    """
    text = clean_transcript(transcript)
    if not text:
        return unavailable("")

    client = _get_client()
    if client is None:
        return unavailable(text)

    try:
        user_content = json.dumps(
            {"transcript": text, "lang": "hi" if (lang or "").lower().startswith("hi") else "en"},
            ensure_ascii=False,
        )
        response = client.messages.create(
            model=ANTHROPIC_MODEL,
            max_tokens=MAX_TOKENS,
            system=SYSTEM_PROMPT,
            messages=[{"role": "user", "content": user_content}],
        )
        reply = "".join(
            block.text for block in response.content
            if getattr(block, "type", "") == "text"
        )
        parsed = parse_llm_reply(reply)
        if parsed is None:
            log.warning("Intent LLM returned an unparseable reply — degrading to unavailable")
            return unavailable(text)
        return {
            "amount": parsed["amount"],
            "recipient_query": parsed["recipient_query"],
            "confidence": parsed["confidence"],
            "transcript": text,
            "parsed_by": "llm",
        }
    except Exception as exc:
        log.warning("Intent LLM call failed (%s) — degrading to unavailable", exc)
        return unavailable(text)


def _reset_for_tests() -> None:
    """Drop the memoised client so a test can swap the provider."""
    global _client, _client_ready
    with _client_lock:
        _client = None
        _client_ready = False
