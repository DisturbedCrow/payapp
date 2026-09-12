#!/usr/bin/env python3
"""
Red-team demo driver (Feature F2).

Runs visible attacks against a live SetuPay backend from a terminal while the
ops dashboard is on the projector. Every scenario prints a colored
BLOCKED / !! SUCCEEDED !! line, and the process exits non-zero if any attack
gets through — so this doubles as a security regression test in CI.

    python -m demo.attack all --base-url http://127.0.0.1:8000
    python -m demo.attack replay --token <attacker JWT>

Scenarios
    replay     re-submits a blob that was already settled  -> duplicate
    forge      bumps the amount x10, keeps the signature   -> invalid_signature
    overlimit  fresh, correctly signed blob for Rs 99,999  -> limit_exceeded
    burst      8 fresh blobs in one batch                  -> velocity
    all        the four above, 3 s apart, paced for the projector

The script signs blobs exactly the way the Flutter client does (ECDSA P-256
over the pipe-delimited canonical payload, DER signature, base64), so a
successful `replay` proves the whole signing path end to end and not just the
rejection path.
"""

import argparse
import base64
import json
import os
import sys
import time
import uuid
from datetime import datetime, timezone

import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

# Importable both as `python -m demo.attack` from backend/ and directly.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from app.services.signing import canonical_payload  # noqa: E402

GREEN, RED, YELLOW, DIM, BOLD, RESET = (
    "\033[92m", "\033[91m", "\033[93m", "\033[2m", "\033[1m", "\033[0m"
)

BLOB_CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".sent_blobs.json")

DEFAULT_ATTACKER = ("attacker@demo.com", "password123")
DEFAULT_VICTIM = ("vivek@demo.com", "password123")
DEFAULT_RECEIVER_EMAIL = "ramesh@demo.com"


# ── Device key: the same shape the Flutter DeviceKeyService produces ──

class DemoDevice:
    """ECDSA P-256 keypair + the client-side canonical signing routine."""

    def __init__(self, device_id=None):
        self.device_id = device_id or f"attack-cli-{uuid.uuid4()}"
        self.private_key = ec.generate_private_key(ec.SECP256R1())

    @property
    def public_key_base64(self) -> str:
        """Compressed point, base64 — matches DeviceKeyService."""
        raw = self.private_key.public_key().public_bytes(
            encoding=serialization.Encoding.X962,
            format=serialization.PublicFormat.CompressedPoint,
        )
        return base64.b64encode(raw).decode()

    @property
    def public_key_pem(self) -> str:
        return self.private_key.public_key().public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        ).decode()

    def sign(self, payload: str) -> str:
        der = self.private_key.sign(payload.encode("utf-8"), ec.ECDSA(hashes.SHA256()))
        return base64.b64encode(der).decode()


def dart_timestamp(dt: datetime = None) -> str:
    """Dart's DateTime.toUtc().toIso8601String() — millisecond precision + Z."""
    dt = (dt or datetime.now(timezone.utc)).astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def make_blob(device: DemoDevice, sender_id: str, receiver_id: str, amount: float,
              limit_at_time: float = 5000.0, handoff="sync") -> dict:
    blob = {
        "id": str(uuid.uuid4()),
        "sender_id": sender_id,
        "receiver_id": receiver_id,
        "amount": amount,
        "timestamp": dart_timestamp(),
        "nonce": str(uuid.uuid4()),
        "status": "pending_sync",
        "is_offline": True,
        "offline_limit_at_time": limit_at_time,
        "handoff_method": handoff,
    }
    blob["device_signature"] = device.sign(canonical_payload(blob))
    blob["sender_public_key"] = device.public_key_base64
    return blob


# ── API client ────────────────────────────────────────────────────

class Client:
    def __init__(self, base_url: str, token: str = None):
        self.base_url = base_url.rstrip("/")
        self.token = token

    def _headers(self):
        h = {"Content-Type": "application/json"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    def login(self, email: str, password: str):
        r = requests.post(f"{self.base_url}/api/auth/login",
                          json={"email": email, "password": password}, timeout=15)
        r.raise_for_status()
        data = r.json()
        self.token = data["access_token"]
        return data["user"]

    def register_device(self, device: DemoDevice):
        r = requests.post(f"{self.base_url}/api/device/register", headers=self._headers(),
                          json={
                              "device_id": device.device_id,
                              "public_key_base64": device.public_key_base64,
                              "public_key_pem": device.public_key_pem,
                              "platform": "attack-cli",
                              "os_version": "demo",
                              "integrity_score": 1.0,
                          }, timeout=15)
        r.raise_for_status()
        return r.json()

    def sync(self, blobs):
        _cache_blobs(blobs)
        r = requests.post(f"{self.base_url}/api/offline/sync", headers=self._headers(),
                          json={"blobs": blobs}, timeout=30)
        r.raise_for_status()
        return r.json()

    def ops_config(self, dash_token: str):
        try:
            r = requests.get(f"{self.base_url}/api/ops/config",
                             params={"token": dash_token}, timeout=10)
            if r.status_code == 200:
                return r.json()
        except requests.RequestException:
            pass
        return None


def _cache_blobs(blobs):
    """Every blob we send is saved so `replay` can resend one verbatim."""
    try:
        existing = json.load(open(BLOB_CACHE)) if os.path.exists(BLOB_CACHE) else []
    except Exception:
        existing = []
    existing.extend(blobs)
    with open(BLOB_CACHE, "w") as f:
        json.dump(existing[-50:], f, indent=2)


# ── Reporting ─────────────────────────────────────────────────────

class Report:
    def __init__(self):
        self.rows = []

    def record(self, scenario, blocked, expected_reason, actual_reason, detail):
        self.rows.append((scenario, blocked, expected_reason, actual_reason, detail))
        if blocked:
            print(f"  {GREEN}{BOLD}[BLOCKED]{RESET} {scenario:<10} "
                  f"reason={actual_reason or '—'}")
        else:
            print(f"  {RED}{BOLD}[!! SUCCEEDED !!]{RESET} {scenario:<10} "
                  f"expected={expected_reason} got={actual_reason or 'accepted'}")
        if detail:
            print(f"            {DIM}AI: {detail}{RESET}")

    @property
    def leaked(self):
        return [r for r in self.rows if not r[1]]

    def summary(self):
        blocked = sum(1 for r in self.rows if r[1])
        print()
        print("=" * 68)
        if self.leaked:
            print(f"  {RED}{BOLD}{len(self.leaked)} ATTACK(S) SUCCEEDED{RESET} "
                  f"— {blocked}/{len(self.rows)} blocked")
            for row in self.leaked:
                print(f"    {RED}·{RESET} {row[0]}: expected {row[2]}, got {row[3] or 'accepted'}")
        else:
            print(f"  {GREEN}{BOLD}ALL {len(self.rows)} ATTACKS BLOCKED{RESET}")
        print("=" * 68)


def banner(title, subtitle=""):
    print()
    print(f"{BOLD}{'─' * 68}{RESET}")
    print(f"{BOLD}  ATTACK · {title}{RESET}")
    if subtitle:
        print(f"  {DIM}{subtitle}{RESET}")
    print(f"{BOLD}{'─' * 68}{RESET}")


def first_result(response):
    results = response.get("results") or []
    return results[0] if results else {}


# ── Scenarios ─────────────────────────────────────────────────────

def scenario_replay(ctx, report):
    banner("REPLAY", "Re-submit a payment that was already settled.")
    blob = make_blob(ctx.device, ctx.attacker_id, ctx.receiver_id, 25.0,
                     limit_at_time=ctx.attacker_limit)
    seed = first_result(ctx.client.sync([blob]))
    print(f"  {DIM}seeded a genuine ₹25 payment → {seed.get('status')} "
          f"({seed.get('reason')}){RESET}")
    if seed.get("status") != "accepted":
        print(f"  {YELLOW}note: the seed payment did not settle; replay still "
              f"exercises the dedup path.{RESET}")

    result = first_result(ctx.client.sync([dict(blob)]))  # byte-identical resend
    reason = result.get("reason")
    blocked = result.get("status") in ("duplicate", "rejected") and reason == "duplicate"
    report.record("replay", blocked, "duplicate", reason, result.get("reason_detail"))


def scenario_forge(ctx, report):
    banner("FORGE", "Tamper with the amount after signing, keep the signature.")
    blob = make_blob(ctx.device, ctx.attacker_id, ctx.receiver_id, 50.0,
                     limit_at_time=ctx.attacker_limit)
    original = blob["amount"]
    blob["amount"] = round(original * 10, 2)   # signature now covers ₹50, blob says ₹500
    blob["offline_limit_at_time"] = 5000.0     # and lie about the authorised limit
    print(f"  {DIM}signed ₹{original:.0f}, submitting ₹{blob['amount']:.0f} "
          f"with the ₹{original:.0f} signature{RESET}")

    result = first_result(ctx.client.sync([blob]))
    reason = result.get("reason")
    blocked = result.get("status") == "rejected" and reason == "invalid_signature"
    report.record("forge", blocked, "invalid_signature", reason, result.get("reason_detail"))
    if not blocked and ctx.enforcement != "enforce":
        print(f"  {YELLOW}  ↳ server is running SIGNATURE_ENFORCEMENT="
              f"{ctx.enforcement}. Set it to `enforce` for the demo.{RESET}")


def scenario_overlimit(ctx, report):
    banner("OVER-LIMIT", "A correctly signed payment for far more than the AI allows.")
    blob = make_blob(ctx.device, ctx.attacker_id, ctx.receiver_id, 99999.0,
                     limit_at_time=99999.0)
    result = first_result(ctx.client.sync([blob]))
    reason = result.get("reason")
    blocked = result.get("status") == "rejected" and reason == "limit_exceeded"
    report.record("overlimit", blocked, "limit_exceeded", reason, result.get("reason_detail"))


def scenario_burst(ctx, report):
    banner("BURST", "8 small payments in one batch — velocity rule must contain it.")
    blobs = [make_blob(ctx.device, ctx.attacker_id, ctx.receiver_id, 7.0,
                       limit_at_time=ctx.attacker_limit) for _ in range(8)]
    response = ctx.client.sync(blobs)
    results = response.get("results", [])
    accepted = [r for r in results if r.get("status") == "accepted"]
    velocity = [r for r in results if r.get("reason") == "velocity"]

    print(f"  {DIM}{len(accepted)} settled, {len(results) - len(accepted)} stopped "
          f"({len(velocity)} by the velocity rule){RESET}")
    blocked = bool(velocity) and len(accepted) <= ctx.velocity_max
    detail = velocity[0].get("reason_detail") if velocity else None
    report.record("burst", blocked, "velocity",
                  "velocity" if velocity else "accepted", detail)


def scenario_control(ctx, report):
    """Not an attack — proves a normal payment still settles right afterwards."""
    banner("CONTROL", "A genuine payment from the trusted user, immediately after.")
    blob = make_blob(ctx.victim_device, ctx.victim_id, ctx.receiver_id, 200.0,
                     limit_at_time=ctx.victim_limit, handoff="qr")
    result = first_result(ctx.victim_client.sync([blob]))
    ok = result.get("status") == "accepted"
    if ok:
        print(f"  {GREEN}{BOLD}[SETTLED]{RESET} control    ₹200 from the trusted user "
              f"went through — signature_verified="
              f"{result.get('signature_verified')}")
    else:
        print(f"  {RED}{BOLD}[BROKEN]{RESET} control    a genuine payment was refused: "
              f"{result.get('reason')} — {result.get('reason_detail')}")
        report.record("control", False, "accepted", result.get("reason"),
                      result.get("reason_detail"))


SCENARIOS = {
    "replay": scenario_replay,
    "forge": scenario_forge,
    "overlimit": scenario_overlimit,
    "burst": scenario_burst,
}


class Ctx:
    pass


def main():
    parser = argparse.ArgumentParser(description="SetuPay red-team demo driver")
    parser.add_argument("scenario", choices=list(SCENARIOS) + ["all"])
    parser.add_argument("--base-url", default=os.getenv("SETUPAY_URL", "http://127.0.0.1:8000"))
    parser.add_argument("--token", help="attacker JWT (skips login)")
    parser.add_argument("--email", default=DEFAULT_ATTACKER[0])
    parser.add_argument("--password", default=DEFAULT_ATTACKER[1])
    parser.add_argument("--dash-token", default=os.getenv("OPS_DASH_TOKEN", "setupay-demo"))
    parser.add_argument("--gap", type=float, default=3.0,
                        help="seconds between scenarios in `all` (paced for the projector)")
    args = parser.parse_args()

    ctx = Ctx()
    ctx.client = Client(args.base_url, args.token)

    print(f"{BOLD}SetuPay red-team{RESET}  target {args.base_url}")

    attacker = ctx.client.login(args.email, args.password) if not args.token else None
    if attacker is None:
        attacker = requests.get(f"{args.base_url}/api/auth/me",
                                headers={"Authorization": f"Bearer {ctx.client.token}"},
                                timeout=15).json()
    ctx.attacker_id = attacker["id"]
    ctx.attacker_limit = float(attacker.get("offline_limit") or 100.0)

    ctx.device = DemoDevice()
    ctx.client.register_device(ctx.device)
    print(f"  attacker  {attacker['full_name']}  limit ₹{ctx.attacker_limit:,.0f}  "
          f"device registered")

    # The trusted user + receiver, for the control payment.
    ctx.victim_client = Client(args.base_url)
    victim = ctx.victim_client.login(*DEFAULT_VICTIM)
    ctx.victim_id = victim["id"]
    ctx.victim_limit = float(victim.get("offline_limit") or 5000.0)
    ctx.victim_device = DemoDevice()
    ctx.victim_client.register_device(ctx.victim_device)

    receiver_client = Client(args.base_url)
    receiver = receiver_client.login(DEFAULT_RECEIVER_EMAIL, "password123")
    ctx.receiver_id = receiver["id"]
    print(f"  victim    {victim['full_name']}  limit ₹{ctx.victim_limit:,.0f}")
    print(f"  receiver  {receiver['full_name']}")

    config = ctx.client.ops_config(args.dash_token) or {}
    ctx.enforcement = config.get("signature_enforcement", "unknown")
    ctx.velocity_max = int(config.get("velocity_max_blobs", 5))
    print(f"  server    signatures={ctx.enforcement}  "
          f"explainer={config.get('explainer_active', '?')}  "
          f"velocity={ctx.velocity_max}/{config.get('velocity_window_min', '?')}min")
    if ctx.enforcement == "log_only":
        print(f"  {YELLOW}WARNING: SIGNATURE_ENFORCEMENT=log_only — forged blobs are "
              f"logged, not rejected.\n           Run the backend with "
              f"SIGNATURE_ENFORCEMENT=enforce for the demo.{RESET}")

    report = Report()
    names = list(SCENARIOS) if args.scenario == "all" else [args.scenario]
    for i, name in enumerate(names):
        SCENARIOS[name](ctx, report)
        if args.scenario == "all" and i < len(names) - 1:
            time.sleep(args.gap)

    if args.scenario == "all":
        time.sleep(min(args.gap, 1.5))
        scenario_control(ctx, report)

    report.summary()
    return 1 if report.leaked else 0


if __name__ == "__main__":
    sys.exit(main())
