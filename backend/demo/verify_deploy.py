#!/usr/bin/env python3
"""
Verify a live SetuPay deployment end to end, from the outside.

    python -m demo.verify_deploy https://setupay-api.onrender.com [OPS_DASH_TOKEN]

Proves config BEHAVIOURALLY rather than by reading env vars (Render masks
them): demo_mode / enforcement / provider come back from /api/ops/config,
auto-seed is proven by logging in as the demo cast, and a working
GEMINI_API_KEY + GEMINI_MODEL is proven by generated_by == "llm".
Exits non-zero on any failure.
"""
import base64, sys, time, uuid
from datetime import datetime, timezone

import requests
from nacl.signing import SigningKey

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
from app.services.signing import canonical_payload_v1  # noqa: E402

B = sys.argv[1].rstrip("/")
TOKEN = sys.argv[2] if len(sys.argv) > 2 else None
ok = fail = 0

def c(name, cond, detail=""):
    global ok, fail
    ok, fail = (ok + 1, fail) if cond else (ok, fail + 1)
    print(f"  {'\033[92mPASS' if cond else '\033[91mFAIL'}\033[0m {name}" + (f"  {detail}" if detail else ""))

def H(t): return {"Authorization": f"Bearer {t}", "Content-Type": "application/json"}

print(f"target {B}\n── waking (free tier cold start) ──")
for i in range(12):
    try:
        r = requests.get(f"{B}/health", timeout=60)
        if r.status_code == 200:
            print(f"  awake after {i+1} attempt(s)"); break
        print(f"  attempt {i+1}: HTTP {r.status_code}")
    except requests.RequestException as e:
        print(f"  attempt {i+1}: {type(e).__name__}")
    time.sleep(10)
else:
    print("  service never became healthy"); sys.exit(2)

print("\n── config, proven behaviourally ──")
c("GET /health", requests.get(f"{B}/health", timeout=40).json().get("status") == "healthy")
if TOKEN:
    cfg = requests.get(f"{B}/api/ops/config", params={"token": TOKEN}, timeout=40)
    j = cfg.json() if cfg.ok else {}
    c("ops token accepted", cfg.ok, f"HTTP {cfg.status_code}")
    c("DEMO_MODE=true", j.get("demo_mode") is True)
    c("SIGNATURE_ENFORCEMENT=enforce", j.get("signature_enforcement") == "enforce", j.get("signature_enforcement"))
    c("EXPLAINER_PROVIDER=gemini", j.get("explainer_provider") == "gemini", j.get("explainer_provider"))
    c("Gemini key live (explainer_active=llm)", j.get("explainer_active") == "llm", j.get("explainer_active"))
c("empty token rejected", requests.get(f"{B}/api/ops/feed", params={"token": ""}, timeout=40).status_code == 403)
c("wrong token rejected", requests.get(f"{B}/api/ops/feed", params={"token": "setupay-demo-wrong"}, timeout=40).status_code == 403)

print("\n── auto-seed (fresh DB must have the demo cast) ──")
def login(e):
    r = requests.post(f"{B}/api/auth/login", json={"email": e, "password": "password123"}, timeout=40)
    return (r.json()["access_token"], r.json()["user"]) if r.ok else (None, None)
atok, ash = login("ashmita@gmail.com"); c("login ashmita", atok is not None, f"limit Rs {ash['offline_limit']:,.0f}" if ash else "")
jtok, jya = login("jyati@gmail.com");   c("login jyati", jtok is not None)
if not (atok and jtok):
    print(f"\n  {ok} passed, {fail} failed"); sys.exit(1)

print("\n── signing, payments, fraud ──")
sk = SigningKey.generate()
c("register Ed25519 key", requests.post(f"{B}/api/auth/device-key", headers=H(atok),
  json={"public_key_b64": base64.b64encode(bytes(sk.verify_key)).decode()}, timeout=40).ok)
def blob(a, key=None):
    d = datetime.now(timezone.utc)
    b = {"id": str(uuid.uuid4()), "sender_id": ash["id"], "receiver_id": jya["id"], "amount": a,
         "timestamp": d.strftime("%Y-%m-%dT%H:%M:%S.") + f"{d.microsecond//1000:03d}Z",
         "nonce": str(uuid.uuid4()), "is_offline": True, "offline_limit_at_time": 5000.0, "handoff_method": "qr"}
    b["device_signature_ed25519"] = base64.b64encode((key or sk).sign(canonical_payload_v1(b).encode()).signature).decode()
    return b
def sync(b): return requests.post(f"{B}/api/offline/sync", headers=H(atok), json={"blobs": [b]}, timeout=40).json()["results"][0]
g = blob(200.0); r = sync(g)
c("signed offline payment settles", r["status"] == "accepted" and r.get("signature_verified"), r.get("reason"))
c("replay refused", sync(dict(g))["status"] == "duplicate")
t = blob(100.0); t["amount"] = 1000.0
c("tampered amount refused (enforce live)", sync(t).get("reason") == "invalid_signature")
c("foreign key refused", sync(blob(50.0, SigningKey.generate())).get("reason") == "invalid_signature")
c("online payment", requests.post(f"{B}/api/payments/online", headers=H(atok),
  json={"receiver_id": jya["id"], "receiver_name": "Jyati", "amount": 25.0, "nonce": str(uuid.uuid4())}, timeout=40).json().get("receiver_credited"))

print("\n── AI ──")
j = requests.get(f"{B}/api/user/limit-explanation", headers=H(atok), params={"lang": "hi"}, timeout=40).json()
c("Gemini explainer (generated_by=llm)", j.get("generated_by") == "llm", f"{j.get('generated_by')} — {j.get('headline')}")
j = requests.post(f"{B}/api/ai/parse-intent", headers=H(atok), json={"transcript": "jyati ko do sau rupaye bhejo"}, timeout=40).json()
c("voice intent via Gemini", j.get("amount") == 200.0 and j.get("parsed_by") == "llm", f"Rs {j.get('amount')} by={j.get('parsed_by')}")

print("\n── remaining routes ──")
for p in ("/api/auth/me", "/api/tokens/active", "/api/sync/status", "/api/dashboard/user", "/api/device/list", "/api/user/offline-limit", "/api/contacts"):
    c(f"GET {p}", requests.get(f"{B}{p}", headers=H(atok), timeout=40).ok)
c("GET /api/dashboard/merchant", requests.get(f"{B}/api/dashboard/merchant", headers=H(jtok), timeout=40).ok)
for p in ("/", "/api/public-key", "/api/app/version"):
    c(f"GET {p}", requests.get(f"{B}{p}", timeout=40).ok)
if TOKEN:
    c("GET /dashboard/live", requests.get(f"{B}/dashboard/live", params={"token": TOKEN}, timeout=40).ok)

print(f"\n{'='*56}\n  {ok} passed, {fail} failed\n{'='*56}")
sys.exit(1 if fail else 0)
