"""
Feature H1/H4 — server-side speech-to-text for voice payments.

`POST /api/ai/transcribe` (multipart: audio_file, lang) proxies a short clip to
Gnani Prisma and returns the transcript plus the rupee amount parsed from its
inverse-text-normalised form ("₹1,50,000").

  * No GNANI_API_KEY → a canned mock rotation (provider "mock"), so the voice
    flow demos on a laptop with nothing configured.
  * Key set but the call fails → HTTP 503 {"fallback": true, ...}; the phone
    keeps its on-device transcript. The key never leaves this process.

200 body (the mobile app's contract — keep these keys exactly):
    {"transcript": str, "provider": "gnani"|"mock", "lang": str,
     "latency_ms": int, "entities": {"amount": float|null}}
"""

import itertools
import logging
import threading
import time
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse
from sqlalchemy.orm import Session

from ..auth import get_current_user
from ..config import GNANI_LANG
from ..database import get_db
from ..models import User
from ..services import gnani

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api/ai", tags=["AI Voice Intent"])

# ≈10 s of 16 kHz mono WAV is ~320 KB; 2 MB leaves room for 60 s of AAC.
MAX_AUDIO_BYTES = 2 * 1024 * 1024

MOCK_TRANSCRIPTS = (
    "ramesh ko 200 rupaye bhejo",
    "jyati ko ₹250 bhejo",
    "send ₹1,500 to ramesh",
)
_mock_counter = itertools.count()
_mock_lock = threading.Lock()


def _next_mock_transcript() -> str:
    with _mock_lock:
        index = next(_mock_counter)
    return MOCK_TRANSCRIPTS[index % len(MOCK_TRANSCRIPTS)]


def _emit(provider: str, lang: str, latency_ms: int, ok: bool, user: User,
          amount: Optional[float] = None) -> None:
    try:
        from ..services import ops_events as ops
        ops.emit(
            "voice_transcribed",
            provider=provider,
            lang=lang,
            latency_ms=latency_ms,
            ok=ok,
            amount=amount,
            user=ops.mask_user(getattr(user, "full_name", ""), getattr(user, "id", "")),
        )
    except Exception:
        pass


@router.post("/transcribe")
def transcribe(
    audio_file: UploadFile = File(...),
    lang: Optional[str] = Form(None),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    lang = (lang or GNANI_LANG).strip()
    if lang not in gnani.SUPPORTED_LANGS:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported lang; expected one of {', '.join(gnani.SUPPORTED_LANGS)}",
        )

    audio = audio_file.file.read(MAX_AUDIO_BYTES + 1)
    if not audio:
        raise HTTPException(status_code=400, detail="audio_file is empty")
    if len(audio) > MAX_AUDIO_BYTES:
        raise HTTPException(status_code=400, detail="audio_file exceeds 2 MB")

    started = time.monotonic()

    if not gnani.is_configured():
        transcript = _next_mock_transcript()
        provider = "mock"
    else:
        result = gnani.transcribe(audio, audio_file.filename or "audio.wav", lang)
        latency_ms = int((time.monotonic() - started) * 1000)
        if not result:
            reason = gnani.last_failure_reason()
            _emit("gnani", lang, latency_ms, False, current_user)
            return JSONResponse(
                status_code=503,
                content={"fallback": True, "provider": "gnani", "reason": reason},
            )
        transcript = result["transcript"]
        provider = "gnani"

    latency_ms = int((time.monotonic() - started) * 1000)
    amount = gnani.extract_amount(transcript)
    _emit(provider, lang, latency_ms, True, current_user, amount)

    return {
        "transcript": transcript,
        "provider": provider,
        "lang": lang,
        "latency_ms": latency_ms,
        "entities": {"amount": amount},
    }
