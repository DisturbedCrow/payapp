"""
Minimal Gemini client, shared by the risk explainer (Feature D) and the voice
intent garnish (Feature G6).

Deliberately plain httpx rather than the google-genai SDK: httpx is already a
dependency, the surface we need is one POST, and a demo-day deploy on Render's
free tier is better off without another package to install and pin.

Contract, in priority order:
  * NEVER raises. Every failure returns None and the caller keeps its
    deterministic fallback (templates for the explainer, the on-device parser
    for voice). A hostile venue network must not be able to break the demo.
  * Hard timeout on every call, no retries — a retry would blow the budget the
    UI is waiting on.
  * Asks for JSON via responseMimeType and still strips code fences before
    parsing, because models occasionally ignore it.
"""

import json
import logging
import re
from typing import Any, Dict, Optional

import httpx

from ..config import (
    GEMINI_API_KEY,
    GEMINI_MODEL,
    LLM_TIMEOUT_SECONDS,
)

log = logging.getLogger(__name__)

_ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
)


def is_configured() -> bool:
    return bool(GEMINI_API_KEY)


def _strip_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    return text.strip()


def generate_json(
    system_prompt: str,
    user_payload: str,
    *,
    max_output_tokens: int = 300,
    temperature: float = 0.4,
    timeout: Optional[float] = None,
    model: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """One JSON-returning call. None on any failure, ever."""
    if not GEMINI_API_KEY:
        return None

    url = _ENDPOINT.format(model=model or GEMINI_MODEL)
    body = {
        "system_instruction": {"parts": [{"text": system_prompt}]},
        "contents": [{"parts": [{"text": user_payload}]}],
        "generationConfig": {
            "maxOutputTokens": max_output_tokens,
            "temperature": temperature,
            "responseMimeType": "application/json",
        },
    }

    try:
        response = httpx.post(
            url,
            json=body,
            headers={
                "Content-Type": "application/json",
                "X-goog-api-key": GEMINI_API_KEY,
            },
            timeout=timeout or LLM_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        data = response.json()

        if "error" in data:
            log.warning("Gemini error: %s", data["error"].get("message"))
            return None

        candidates = data.get("candidates") or []
        if not candidates:
            # Usually a safety block; the caller falls back silently.
            log.warning("Gemini returned no candidates: %s",
                        data.get("promptFeedback"))
            return None

        parts = candidates[0].get("content", {}).get("parts") or []
        text = "".join(p.get("text", "") for p in parts)
        if not text.strip():
            return None

        parsed = json.loads(_strip_fences(text))
        return parsed if isinstance(parsed, dict) else None

    except httpx.TimeoutException:
        log.warning("Gemini timed out after %.1fs — falling back",
                    timeout or LLM_TIMEOUT_SECONDS)
        return None
    except Exception as exc:
        log.warning("Gemini call failed (%s) — falling back", exc)
        return None
