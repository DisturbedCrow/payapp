"""
GenAI risk explainer (Feature D).

Turns the sklearn risk model's invisible feature vector into plain-language
(English or Hinglish) copy the user — and a judge at the back of a hall —
can actually read.

Two providers, selected by EXPLAINER_PROVIDER:

  MockExplainer       deterministic templates. ALWAYS present, and the
                      fallback for every failure path of the LLM provider.
                      Renders in well under 50 ms with no network.
  AnthropicExplainer  Claude Messages API, 2-second timeout, JSON-only
                      response, silently degrades to MockExplainer on ANY
                      exception.

Rejection explanations are mock-first on purpose: rejections happen live
during the fraud demo and must render instantly.
"""

import json
import logging
import re
import threading
import time
import zlib
from typing import Any, Dict, List, Optional, Tuple

from ..config import (
    ANTHROPIC_API_KEY,
    ANTHROPIC_MODEL,
    EXPLAINER_CACHE_TTL_SECONDS,
    EXPLAINER_PROVIDER,
    EXPLAINER_TIMEOUT_SECONDS,
)

log = logging.getLogger(__name__)


# ── Formatting helpers ────────────────────────────────────────────

def rupees(amount: float) -> str:
    """₹5,000 with Indian digit grouping — not ₹5000.00."""
    n = int(round(float(amount)))
    s = str(abs(n))
    if len(s) > 3:
        head, tail = s[:-3], s[-3:]
        parts = []
        while len(head) > 2:
            parts.insert(0, head[-2:])
            head = head[:-2]
        if head:
            parts.insert(0, head)
        s = ",".join(parts) + "," + tail
    return ("-" if n < 0 else "") + "₹" + s


# ── Feature table ─────────────────────────────────────────────────
# direction is derived from backend/app/services/risk_engine.py: features
# that push the heuristic/ML risk score DOWN raise the limit, and vice versa.

_FEATURE_DIRECTION = {
    "kyc_tier": "raises",
    "device_trust_score": "raises",
    "transaction_count": "raises",
    "account_age_days": "raises",
    "avg_transaction_value": "raises",
    "fraud_flags": "lowers",
    "pending_unsynced_payments": "lowers",
    "hours_since_last_sync": "lowers",
}

# Human phrasing per feature, in both languages. {v} is the value.
_PHRASES = {
    "en": {
        "kyc_tier": ("your KYC is verified to tier {v}", "your KYC is only at tier {v}"),
        "device_trust_score": ("this phone has a strong trust score", "this phone is still building trust"),
        "transaction_count": ("you have {v} completed payments behind you", "you have only {v} payments so far"),
        "account_age_days": ("your account is {v} days old", "your account is only {v} days old"),
        "avg_transaction_value": ("your payments are steady and predictable", "we have little spending history yet"),
        "fraud_flags": ("no payment has ever been flagged", "{v} earlier {plural_payment_bare} was flagged"),
        "pending_unsynced_payments": ("everything is synced up", "{v} {plural_payment_bare} {plural_verb} still waiting to sync"),
        "hours_since_last_sync": ("you synced in the last few hours", "it has been {v} hours since your last sync"),
    },
    "hi": {
        "kyc_tier": ("aapka KYC tier {v} tak verified hai", "aapka KYC abhi sirf tier {v} par hai"),
        "device_trust_score": ("is phone ka trust score strong hai", "yeh phone abhi trust bana raha hai"),
        "transaction_count": ("aapke {v} payments successfully complete ho chuke hain", "abhi tak sirf {v} payments hue hain"),
        "account_age_days": ("aapka account {v} din purana hai", "aapka account abhi sirf {v} din purana hai"),
        "avg_transaction_value": ("aapke payments steady aur predictable hain", "abhi spending history kam hai"),
        "fraud_flags": ("aaj tak koi payment flag nahi hui", "{v} purani payment flag hui thi"),
        "pending_unsynced_payments": ("sab kuch sync ho chuka hai", "{v} {plural_payment} abhi sync hone ka wait kar rahi {plural_verb}"),
        "hours_since_last_sync": ("aapne abhi kuch ghante pehle sync kiya tha", "{v} ghante se sync nahi hua hai"),
    },
}

# 5 template variants per language so repeated demos never look canned.
_BODY_TEMPLATES = {
    "en": [
        "Your offline limit is {limit} because {pos} and {neg}.",
        "We set {limit} for offline payments: {pos}, but {neg}.",
        "{limit} is available offline right now — {pos}, though {neg}.",
        "Right now you can spend {limit} without a network. That is because {pos} while {neg}.",
        "Offline you have {limit}. The two things that decided it: {pos}, and {neg}.",
    ],
    "hi": [
        "Aapki offline limit {limit} hai kyunki {pos} aur {neg}.",
        "Humne offline ke liye {limit} set ki hai: {pos}, lekin {neg}.",
        "Abhi {limit} offline available hai — {pos}, magar {neg}.",
        "Bina network ke aap abhi {limit} kharch kar sakte hain. Kyunki {pos} jabki {neg}.",
        "Offline aapke paas {limit} hai. Do cheezein isko decide karti hain: {pos}, aur {neg}.",
    ],
}

_TIPS = {
    "en": {
        "pending_unsynced_payments": "Get online for a few seconds — syncing your pending payments raises this straight away.",
        "hours_since_last_sync": "Connect to the internet once today; a fresh sync lifts your limit immediately.",
        "kyc_tier": "Finish the next KYC step in Profile to unlock a higher offline limit.",
        "fraud_flags": "Keep paying normally for a few days and the flag stops counting against you.",
        "device_trust_score": "Keep using this same phone — device trust builds up on its own.",
        "default": "Sync once a day and complete your KYC — those two lift the limit fastest.",
    },
    "hi": {
        "pending_unsynced_payments": "Bas kuch second online aa jaiye — pending payments sync hote hi limit badh jayegi.",
        "hours_since_last_sync": "Aaj ek baar internet se connect kariye; fresh sync se limit turant badhegi.",
        "kyc_tier": "Profile mein agla KYC step complete kariye, offline limit badh jayegi.",
        "fraud_flags": "Kuch din normal payments kariye, flag ka asar khatam ho jayega.",
        "device_trust_score": "Isi phone se payment karte rahiye — device trust apne aap banta hai.",
        "default": "Din mein ek baar sync kariye aur KYC poora kariye — limit sabse tezi se inhi se badhti hai.",
    },
}

_HEADLINES = {
    "en": "Your offline limit: {limit}",
    "hi": "Aapki offline limit: {limit}",
}

_ZERO_LIMIT = {
    "en": {
        "headline": "Offline pay is paused for now",
        "body": "Offline payments are temporarily paused for your safety, {neg}. Nothing is wrong with your money — your balance is untouched.",
        "tip": "Connect to the internet once and sync; that usually restores the limit right away.",
    },
    "hi": {
        "headline": "Offline pay abhi paused hai",
        "body": "Aapki safety ke liye offline payments filhaal paused hain, {neg}. Paise bilkul safe hain — balance par koi asar nahi.",
        "tip": "Ek baar internet se connect karke sync kar lijiye, limit aam taur par turant wapas aa jati hai.",
    },
}

# ── Rejection templates (mock-first, always instant) ───────────────

_REJECTION_TEMPLATES = {
    "duplicate": {
        "en": "This payment repeats one we already settled{when} — ignored so {who} is not charged twice.",
        "hi": "Yeh payment pehle hi settle ho chuki hai{when} — ignore kar di, taaki {who} se do baar paisa na kate.",
    },
    "invalid_signature": {
        "en": "The payment details do not match the phone's signature — someone edited this after it was signed, so it was not settled.",
        "hi": "Payment details phone ke signature se match nahi karte — sign hone ke baad kisi ne badla hai, isliye settle nahi kiya.",
    },
    "unsigned_device": {
        "en": "This payment came from a device we have never seen a key for, so it could not be settled.",
        "hi": "Yeh payment aise device se aayi hai jiski key registered nahi hai, isliye settle nahi ho payi.",
    },
    "limit_exceeded": {
        "en": "{amount} is above the offline limit the AI set for this account, so it was held back.",
        "hi": "{amount} is account ki AI-set offline limit se zyada hai, isliye rok diya gaya.",
    },
    "velocity": {
        "en": "Too many offline payments from this account in a few minutes — held back until it syncs.",
        "hi": "Kuch hi minutes mein bahut saari offline payments — sync hone tak rok di gayi hain.",
    },
    "insufficient_balance": {
        "en": "{amount} is more than the balance on this account, so nothing was moved.",
        "hi": "{amount} account ke balance se zyada hai, isliye koi paisa transfer nahi hua.",
    },
    "invalid_amount": {
        "en": "The amount on this payment is not a real amount, so it was dropped.",
        "hi": "Is payment ki amount valid nahi hai, isliye ise drop kar diya.",
    },
    "timestamp": {
        "en": "This payment is dated outside the 72-hour offline window, so it can no longer be settled.",
        "hi": "Yeh payment 72-ghante ki offline window ke bahar ki hai, ab settle nahi ho sakti.",
    },
    "fraud": {
        "en": "Our fraud checks flagged this payment, so it was held back for review.",
        "hi": "Fraud checks ne is payment ko flag kiya hai, isliye review ke liye rok di gayi.",
    },
    "sender_not_found": {
        "en": "We could not find the account this payment came from, so it was dropped.",
        "hi": "Jis account se yeh payment aayi hai woh mila nahi, isliye drop kar di.",
    },
}

_REJECTION_FALLBACK = {
    "en": "This payment was held back by our AI trust checks.",
    "hi": "AI trust checks ne is payment ko rok diya.",
}


def _lang(lang: Optional[str]) -> str:
    return "hi" if (lang or "en").lower().startswith("hi") else "en"


def _split_features(features: List[Dict[str, Any]]) -> Tuple[Optional[dict], Optional[dict]]:
    """Return the strongest positive and strongest negative feature."""
    positives = [f for f in features if f.get("direction") == "raises"]
    negatives = [f for f in features if f.get("direction") == "lowers"]
    key = lambda f: -abs(float(f.get("weight", 0) or 0))
    positives.sort(key=key)
    negatives.sort(key=key)
    return (positives[0] if positives else None, negatives[0] if negatives else None)


def _phrase(feature: Optional[dict], lang: str, positive: bool) -> Optional[str]:
    if not feature:
        return None
    name = feature.get("name")
    table = _PHRASES.get(lang, _PHRASES["en"]).get(name)
    if not table:
        return None
    text = table[0] if positive else table[1]
    value = feature.get("value")
    if isinstance(value, float):
        value = int(value) if value == int(value) else round(value, 1)
    one = value == 1
    if lang == "hi":
        plural_payment, plural_verb = ("payment", "hai") if one else ("payments", "hain")
    else:
        plural_payment, plural_verb = ("payment", "is") if one else ("payments", "are")
    return text.format(v=value, plural_payment=plural_payment,
                       plural_payment_bare=plural_payment, plural_verb=plural_verb)


class Explainer:
    """Interface both providers implement."""

    def explain_limit(self, payload: dict, lang: str = "en") -> dict:
        raise NotImplementedError

    def explain_rejection(self, blob: dict, reason: str, lang: str = "en") -> str:
        raise NotImplementedError


class MockExplainer(Explainer):
    """Deterministic templates. Required, always present, always the fallback."""

    def explain_limit(self, payload: dict, lang: str = "en") -> dict:
        lang = _lang(lang)
        limit = float(payload.get("limit", 0) or 0)
        features = payload.get("features", []) or []
        pos, neg = _split_features(features)

        limit_text = rupees(limit)
        neg_text = _phrase(neg, lang, positive=False)
        pos_text = _phrase(pos, lang, positive=True)

        if limit <= 0:
            tpl = _ZERO_LIMIT[lang]
            return {
                "headline": tpl["headline"],
                "body": tpl["body"].format(
                    neg=neg_text or ("kyunki abhi trust signals kam hain" if lang == "hi"
                                     else "while we build up trust signals")),
                "tip": tpl["tip"],
            }

        # Vary the template deterministically per (user, limit) so a given
        # user sees a stable card, but different users/limits read differently.
        seed = f"{payload.get('user_id','')}|{int(limit)}|{lang}"
        variants = _BODY_TEMPLATES[lang]
        # crc32 rather than hash(): Python randomises str hashing per
        # process, and the card must read the same across restarts.
        body_tpl = variants[zlib.crc32(seed.encode()) % len(variants)]

        if not pos_text:
            pos_text = "aapka account active hai" if lang == "hi" else "your account is in good standing"
        if not neg_text:
            neg_text = ("aur koi risk signal nahi hai" if lang == "hi"
                        else "nothing is currently working against you")

        tip_key = (neg or {}).get("name", "default")
        tip = _TIPS[lang].get(tip_key, _TIPS[lang]["default"])

        return {
            "headline": _HEADLINES[lang].format(limit=limit_text),
            "body": body_tpl.format(limit=limit_text, pos=pos_text, neg=neg_text),
            "tip": tip,
        }

    def explain_rejection(self, blob: dict, reason: str, lang: str = "en") -> str:
        lang = _lang(lang)
        template = _REJECTION_TEMPLATES.get(reason, {}).get(lang)
        if not template:
            return _REJECTION_FALLBACK[lang]
        when = ""
        settled_at = (blob or {}).get("settled_at_display")
        if settled_at:
            when = (f" {settled_at} par" if lang == "hi" else f" at {settled_at}")
        return template.format(
            when=when,
            who=(blob or {}).get("sender_display", "the sender" if lang == "en" else "sender"),
            amount=rupees((blob or {}).get("amount", 0)),
        )


_SYSTEM_PROMPT = """You are the in-app explainer for SetuPay, an offline-first payment app in India.
You explain the user's AI-assigned offline credit limit in plain, warm, consumer
language. You will receive a JSON payload of model features and the resulting
limit. Rules:

1. Output ONLY valid JSON: {"headline": str, "body": str, "tip": str}. No
   markdown, no code fences, no extra keys.
2. "headline": max 8 words, states the limit. Example: "Your offline limit: ₹1,500".
3. "body": 2–3 short sentences. Name the TOP TWO factors that most influenced
   the limit (from the payload's feature list), one positive and one negative
   where both exist. Use ₹ with Indian digit grouping (₹5,000 not ₹5000.00).
4. "tip": ONE actionable sentence telling the user the fastest way to raise
   their limit (e.g. sync pending payments, complete KYC).
5. NEVER invent numbers, factors, or policies not present in the payload.
6. No jargon: say "payments waiting to sync", not "pending blobs"; say "trust
   score", not "risk score".
7. If lang == "hi", write body and tip in conversational Hinglish (Roman
   script, Hindi sentence structure with common English fintech words), e.g.
   "Aapki 3 payments abhi sync hone ka wait kar rahi hain."
8. Tone: reassuring, never accusatory, even at low limits. A ₹0 limit is
   framed as "temporarily paused for your safety"."""


def _strip_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    return text.strip()


class AnthropicExplainer(Explainer):
    """Claude Messages API with a hard 2 s budget and a silent mock fallback."""

    def __init__(self) -> None:
        self._mock = MockExplainer()
        self._client = None
        try:
            import anthropic  # imported lazily so the package stays optional
            if ANTHROPIC_API_KEY:
                self._client = anthropic.Anthropic(
                    api_key=ANTHROPIC_API_KEY,
                    timeout=EXPLAINER_TIMEOUT_SECONDS,
                    max_retries=0,  # a retry would blow the 2 s stage budget
                )
        except Exception as exc:  # pragma: no cover - depends on env
            log.warning("AnthropicExplainer unavailable, using templates: %s", exc)

    def explain_limit(self, payload: dict, lang: str = "en") -> dict:
        if self._client is None:
            return self._mock.explain_limit(payload, lang)
        try:
            user_payload = dict(payload)
            user_payload["lang"] = _lang(lang)
            response = self._client.messages.create(
                model=ANTHROPIC_MODEL,
                max_tokens=300,
                system=_SYSTEM_PROMPT,
                messages=[{"role": "user", "content": json.dumps(user_payload)}],
            )
            text = "".join(
                block.text for block in response.content if getattr(block, "type", "") == "text"
            )
            parsed = json.loads(_strip_fences(text))
            headline = str(parsed["headline"]).strip()
            body = str(parsed["body"]).strip()
            tip = str(parsed["tip"]).strip()
            if not (headline and body and tip):
                raise ValueError("empty field in LLM response")
            return {"headline": headline, "body": body, "tip": tip}
        except Exception as exc:
            log.warning("Explainer LLM call failed (%s) — falling back to templates", exc)
            return self._mock.explain_limit(payload, lang)

    def explain_rejection(self, blob: dict, reason: str, lang: str = "en") -> str:
        # Deliberately template-only: rejections render during the live fraud
        # demo and must never wait on a network round-trip.
        return self._mock.explain_rejection(blob, reason, lang)


# ── Provider selection + cache ────────────────────────────────────

_provider: Optional[Explainer] = None
_provider_lock = threading.Lock()
_cache: Dict[Tuple[str, str], Tuple[float, dict]] = {}
_cache_lock = threading.Lock()


def get_explainer() -> Explainer:
    global _provider
    if _provider is None:
        with _provider_lock:
            if _provider is None:
                if EXPLAINER_PROVIDER == "anthropic":
                    _provider = AnthropicExplainer()
                else:
                    _provider = MockExplainer()
    return _provider


def uses_llm() -> bool:
    provider = get_explainer()
    return isinstance(provider, AnthropicExplainer) and provider._client is not None


def explain_limit_cached(user_id: str, payload: dict, lang: str = "en") -> Tuple[dict, bool]:
    """Returns (result, was_cached). TTL keeps polling from burning tokens."""
    lang = _lang(lang)
    key = (user_id, lang)
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and hit[0] > now:
            return hit[1], True

    result = get_explainer().explain_limit(payload, lang)
    with _cache_lock:
        _cache[key] = (now + EXPLAINER_CACHE_TTL_SECONDS, result)
    return result, False


def invalidate_user(user_id: str) -> None:
    """Drop a user's cached explanation so the card visibly updates after sync."""
    with _cache_lock:
        for lang in ("en", "hi"):
            _cache.pop((user_id, lang), None)


def explain_rejection(blob: dict, reason: str, lang: str = "en") -> str:
    return get_explainer().explain_rejection(blob, reason, lang)


def build_feature_payload(user, pending_unsynced: int = 0, hours_since_last_sync: Optional[float] = None,
                          risk_factors: Optional[dict] = None) -> List[Dict[str, Any]]:
    """Build the feature list for the LLM/template from real user data only.

    Never fabricates: a feature is omitted when the value is not available.
    `weight` comes from the model's own feature importances when the sklearn
    model is loaded, so the top-two selection tracks the actual model.
    """
    risk_factors = risk_factors or {}
    raw: List[Tuple[str, Any]] = []

    if user.kyc_tier is not None:
        raw.append(("kyc_tier", int(user.kyc_tier)))
    if user.device_trust_score is not None:
        raw.append(("device_trust_score", round(float(user.device_trust_score), 2)))
    if user.transaction_count is not None:
        raw.append(("transaction_count", int(user.transaction_count)))
    if user.created_at is not None:
        from datetime import datetime
        raw.append(("account_age_days", max(0, (datetime.utcnow() - user.created_at).days)))
    if user.avg_transaction_amount:
        raw.append(("avg_transaction_value", round(float(user.avg_transaction_amount))))
    if user.fraud_flags is not None:
        raw.append(("fraud_flags", int(user.fraud_flags)))
    if pending_unsynced:
        raw.append(("pending_unsynced_payments", int(pending_unsynced)))
    if hours_since_last_sync is not None:
        raw.append(("hours_since_last_sync", int(hours_since_last_sync)))

    features: List[Dict[str, Any]] = []
    for name, value in raw:
        direction = _FEATURE_DIRECTION.get(name, "neutral")
        # A "raises" feature at its floor actually works against the user, and
        # a "lowers" feature at zero is a positive. Flip so the copy is honest.
        if name == "fraud_flags" and value == 0:
            direction = "raises"
        elif name == "kyc_tier" and value <= 1:
            direction = "lowers"
        elif name == "device_trust_score" and value < 0.6:
            direction = "lowers"
        elif name == "transaction_count" and value < 5:
            direction = "lowers"
        elif name == "account_age_days" and value < 30:
            direction = "lowers"
        elif name == "hours_since_last_sync" and value < 6:
            direction = "raises"
        elif name == "avg_transaction_value" and int(user.transaction_count or 0) < 5:
            direction = "lowers"

        features.append({
            "name": name,
            "value": value,
            "direction": direction,
            "weight": round(float(risk_factors.get(name, 0.1) or 0.1), 4),
        })
    return features
