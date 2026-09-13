"""
Gnani Prisma speech-to-text client (Feature H1/H4).

    POST https://api.vachana.ai/stt/v3   multipart/form-data
    header  X-API-Key-ID: <key>
    fields  audio_file, language_code, format, itn_native_numerals

`format=transcribe` turns on inverse text normalisation, so a spoken
"do sau pachas rupaye" comes back as "₹250" and a lakh as "₹1,50,000" —
which is what makes the amount extractable. `itn_native_numerals=false`
keeps the digits ASCII (true would return "₹२५०").

Same contract as the Gemini client:
  * NEVER raises. Every failure returns None; the route turns that into a
    503 {"fallback": true} and the phone keeps its on-device transcript.
  * One hard timeout, no retries.
  * The API key is never logged and never returned.
"""

import logging
import mimetypes
import os
import re
import threading
from typing import Any, Dict, Optional

import httpx

from ..config import (
    GNANI_API_KEY,
    GNANI_STT_URL,
    GNANI_TIMEOUT_SECONDS,
)

log = logging.getLogger(__name__)

SUPPORTED_LANGS = (
    "bn-IN", "en-IN", "gu-IN", "hi-IN", "kn-IN",
    "ml-IN", "mr-IN", "pa-IN", "ta-IN", "te-IN",
)

# Why the last transcribe() call on this thread returned None. Short,
# enum-like and secret-free, so the route can put it in the 503 body.
_failure = threading.local()


def is_configured() -> bool:
    return bool(GNANI_API_KEY)


def last_failure_reason() -> str:
    return getattr(_failure, "reason", None) or "stt_unavailable"


def _fail(reason: str) -> None:
    _failure.reason = reason
    return None


_AUDIO_TYPES = {
    ".wav": "audio/wav", ".mp3": "audio/mpeg", ".ogg": "audio/ogg",
    ".flac": "audio/flac", ".aac": "audio/aac", ".m4a": "audio/mp4",
}


def _content_type(filename: str) -> str:
    # Explicit table first: mimetypes says "audio/x-wav" on some platforms.
    ext = os.path.splitext(filename)[1].lower()
    return _AUDIO_TYPES.get(ext) or mimetypes.guess_type(filename)[0] or "audio/wav"


def transcribe(
    audio_bytes: bytes,
    filename: str,
    lang: str,
    *,
    timeout: Optional[float] = None,
) -> Optional[Dict[str, Any]]:
    """One STT call. Returns {"transcript", "request_id"} or None, never raises."""
    _failure.reason = None
    if not GNANI_API_KEY:
        return _fail("not_configured")

    try:
        name = os.path.basename(filename or "") or "audio.wav"
        response = httpx.post(
            GNANI_STT_URL,
            headers={"X-API-Key-ID": GNANI_API_KEY},
            data={
                "language_code": lang,
                "format": "transcribe",
                "itn_native_numerals": "false",
            },
            files={"audio_file": (name, audio_bytes, _content_type(name))},
            timeout=timeout or GNANI_TIMEOUT_SECONDS,
        )

        if response.status_code != 200:
            error_type = ""
            try:
                error_type = ((response.json() or {}).get("error") or {}).get("type", "")
            except Exception:
                pass
            log.warning("Gnani STT HTTP %s %s — falling back",
                        response.status_code, error_type)
            return _fail(f"http_{response.status_code}")

        data = response.json()
        if not isinstance(data, dict) or data.get("success") is not True:
            error = data.get("error") if isinstance(data, dict) else None
            log.warning("Gnani STT rejected the request (%s) — falling back",
                        (error or {}).get("type", "unknown") if isinstance(error, dict) else "unknown")
            return _fail("provider_error")

        transcript = data.get("transcript")
        if not isinstance(transcript, str) or not transcript.strip():
            log.info("Gnani STT returned no transcript — falling back")
            return _fail("no_transcript")

        return {"transcript": transcript.strip(), "request_id": data.get("request_id")}

    except httpx.TimeoutException:
        log.warning("Gnani STT timed out after %.1fs — falling back",
                    timeout or GNANI_TIMEOUT_SECONDS)
        return _fail("timeout")
    except Exception as exc:
        # Type name only: an httpx error string can carry the request URL.
        log.warning("Gnani STT call failed (%s) — falling back", type(exc).__name__)
        return _fail("transport_error")


# ── Amount extraction ──────────────────────────────────────────────

_DEVANAGARI_DIGITS = str.maketrans("०१२३४५६७८९", "0123456789")

_NUMBER = r"(\d[\d,]*(?:\.\d+)?)"
_AMOUNT_PATTERNS = (
    # ITN output: ₹250, ₹ 1,500, ₹1,50,000, ₹3.50
    re.compile(r"₹\s*" + _NUMBER),
    # Rs 250, Rs. 250, INR 250
    re.compile(r"\b(?:rs\.?|inr)\s*" + _NUMBER, re.IGNORECASE),
    # 250 rupaye / 250 rupees / 250 रुपये / 250₹
    re.compile(
        _NUMBER + r"\s*(?:₹|rs\b|inr\b|rupaye|rupaiye|rupay|rupiya|rupya|rupees?"
        r"|रुपये|रुपए|रूपये|रूपए|रुपया|रूपया)",
        re.IGNORECASE,
    ),
)


def extract_amount(transcript: Optional[str]) -> Optional[float]:
    """The first rupee amount in an ITN transcript, or None."""
    if not transcript or not isinstance(transcript, str):
        return None
    text = transcript.translate(_DEVANAGARI_DIGITS)
    for pattern in _AMOUNT_PATTERNS:
        match = pattern.search(text)
        if not match:
            continue
        try:
            value = float(match.group(1).replace(",", ""))
        except ValueError:
            continue
        if value > 0:
            return value
    return None
