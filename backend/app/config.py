import os
import base64
from nacl.signing import SigningKey

# JWT 
SECRET_KEY = os.getenv("SECRET_KEY", "hackathon-offline-pay-secret-2024")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24  # 24 hours

# Database 
# Render injects DATABASE_URL as postgres://...  SQLAlchemy needs postgresql://
_raw_db_url = os.getenv("DATABASE_URL", "sqlite:///./offline_pay.db")
DATABASE_URL = _raw_db_url.replace("postgres://", "postgresql://", 1)

# Ed25519 Key Management 
# On Render the filesystem is ephemeral, so keys are stored as env vars
# (base64-encoded raw bytes). Falls back to file-based for local dev.

def load_or_create_signing_keys() -> SigningKey:
    # 1. Try env var (production on Render)
    key_b64 = os.getenv("ED25519_PRIVATE_KEY_B64")
    if key_b64:
        return SigningKey(base64.b64decode(key_b64))

    # 2. Try local key file (development)
    keys_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "keys")
    key_file = os.path.join(keys_dir, "ed25519.key")
    if os.path.exists(key_file):
        with open(key_file, "rb") as f:
            return SigningKey(f.read())

    # 3. Generate fresh keys (first run / ephemeral env without env var set)
    signing_key = SigningKey.generate()
    os.makedirs(keys_dir, exist_ok=True)
    with open(key_file, "wb") as f:
        f.write(bytes(signing_key))
    pub_file = os.path.join(keys_dir, "ed25519.pub")
    with open(pub_file, "wb") as f:
        f.write(bytes(signing_key.verify_key))

    # Print the base64 value so the operator can paste it into Render env vars
    print("=== NEW ED25519 KEY GENERATED ===")
    print("Set this as ED25519_PRIVATE_KEY_B64 in your Render env vars:")
    print(base64.b64encode(bytes(signing_key)).decode())
    print("=================================")
    return signing_key


SIGNING_KEY = load_or_create_signing_keys()
VERIFY_KEY = SIGNING_KEY.verify_key
PUBLIC_KEY_HEX = VERIFY_KEY.encode().hex()

# Offline Limits 
MAX_OFFLINE_LIMIT = 5000.0
MIN_OFFLINE_LIMIT = 100.0
DEFAULT_TOKEN_EXPIRY_HOURS = 24
MAX_TOKENS_PER_REQUEST = 10
TOKEN_DENOMINATIONS = [50.0, 100.0, 200.0, 500.0, 1000.0]

# ML Model 
ML_MODEL_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ml_model")
ML_MODEL_PATH = os.path.join(ML_MODEL_DIR, "risk_model.joblib")


# ── Demo-day feature flags (Sept 13 sprint) ───────────────────────
# Everything below is env-driven with demo-safe defaults so the stack
# boots on a laptop with no configuration at all.

def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


APP_NAME = os.getenv("APP_NAME", "SetuPay")

# Master switch. In DEMO_MODE fraud rules reject; otherwise they flag only.
DEMO_MODE = _env_bool("DEMO_MODE", True)

# log_only  → signature failures are recorded + surfaced on the ops dashboard
#             but the blob still settles (safe default while phones are being
#             provisioned).
# enforce   → signature failures reject the blob.
SIGNATURE_ENFORCEMENT = os.getenv("SIGNATURE_ENFORCEMENT", "log_only").strip().lower()

# GenAI risk explainer + voice intent garnish.
# "mock" is always available and is the fallback for every failure path of
# every live provider — the demo never depends on a network call succeeding.
#   gemini    Google Generative Language API (default; cheapest flash-lite)
#   anthropic Claude Messages API
#   mock      deterministic templates only
EXPLAINER_PROVIDER = os.getenv("EXPLAINER_PROVIDER", "gemini").strip().lower()

# Gemini. flash-lite is the cheapest tier and is comfortably sufficient here:
# both jobs are short, structured extractions. `-latest` tracks the current
# cheapest flash-lite rather than pinning a version that gets retired.
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-flash-lite-latest")

ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.getenv("ANTHROPIC_MODEL", "claude-sonnet-5")

# Shared ceiling for any live LLM call. Measured: gemini-flash-lite-latest
# averages ~1.2s for these prompts, so 2.0s leaves little headroom on a bad
# network — but the fallback is instant and invisible, so a miss costs nothing
# beyond losing the "AI" badge on that render.
LLM_TIMEOUT_SECONDS = float(os.getenv("LLM_TIMEOUT_SECONDS", "3.0"))
EXPLAINER_TIMEOUT_SECONDS = float(
    os.getenv("EXPLAINER_TIMEOUT_SECONDS", str(LLM_TIMEOUT_SECONDS))
)
EXPLAINER_CACHE_TTL_SECONDS = int(os.getenv("EXPLAINER_CACHE_TTL_SECONDS", "300"))

# Live ops dashboard (projector page) — gated by a token query param.
OPS_DASH_TOKEN = os.getenv("OPS_DASH_TOKEN", "setupay-demo")

# Velocity rule (Feature F). Deterministic — no randomness on stage.
VELOCITY_MAX_BLOBS = int(os.getenv("VELOCITY_MAX_BLOBS", "5"))
VELOCITY_WINDOW_MIN = int(os.getenv("VELOCITY_WINDOW_MIN", "10"))
