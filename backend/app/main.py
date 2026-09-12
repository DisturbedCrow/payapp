import os
from datetime import datetime, timedelta, timezone
from fastapi import FastAPI, Depends
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
from .database import init_db, get_db, SessionLocal
from .routes import (
    auth_routes,
    token_routes,
    sync_routes,
    dashboard,
    device_routes,
    explain_routes,
    ops_routes,
    contact_routes,
    ai_routes,
)
from .auth import get_current_user
from .models import User
from .services.risk_engine import compute_risk_score, compute_offline_limit

app = FastAPI(
    title="SetuPay API",
    description="AI-powered offline payment system backend",
    version="1.0.0",
)

# CORS - allow all origins for hackathon
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=".*",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(auth_routes.router)
app.include_router(token_routes.router)
app.include_router(sync_routes.router)
app.include_router(dashboard.router)
app.include_router(device_routes.router)
app.include_router(explain_routes.router)
app.include_router(ops_routes.router)
app.include_router(contact_routes.router)
app.include_router(ai_routes.router)


@app.on_event("startup")
def startup_event():
    """Initialize database and train ML model on startup."""
    init_db()
    print("Database initialized.")

    # create_all() never adds columns to existing tables; apply the guarded
    # ALTERs for columns added after the first deploy.
    try:
        from scripts.add_columns import ensure_columns
        ensure_columns(verbose=False)
    except Exception as exc:
        print(f"Warning: column migration skipped: {exc}")

    # Seed the ops dashboard's Trust Engine panel from the database so the
    # projector shows real limit bars before the first payment of the demo.
    try:
        from .services import ops_events as ops
        db = SessionLocal()
        try:
            for user in db.query(User).order_by(User.offline_limit.desc()).limit(6).all():
                limit, risk = _current_limit_for(user)
                if limit > 0:
                    ops.note_limit(ops.mask_user(user.full_name, user.id), limit, risk)
        finally:
            db.close()
    except Exception as exc:
        print(f"Warning: could not prime ops dashboard: {exc}")

    # Try to train ML model if not already trained
    from .config import ML_MODEL_PATH
    import os
    if not os.path.exists(ML_MODEL_PATH):
        try:
            from .ml.train_model import train_model
            train_model()
            print("ML risk model trained successfully.")
        except Exception as e:
            print(f"Warning: Could not train ML model: {e}")
            print("Using heuristic risk scoring as fallback.")


# Stored timestamps are naive UTC. The demo runs in India and the projector
# clock is local, so user-facing times are rendered in Asia/Kolkata.
_DISPLAY_TZ = os.getenv("DISPLAY_TZ", "Asia/Kolkata")


def _local_hhmm(dt) -> str:
    if not dt:
        return ""
    try:
        from zoneinfo import ZoneInfo
        return dt.replace(tzinfo=timezone.utc).astimezone(ZoneInfo(_DISPLAY_TZ)).strftime("%H:%M")
    except Exception:
        return dt.strftime("%H:%M")


def _current_limit_for(user: User):
    """Recompute a user's AI offline limit + risk score from live features.

    Returned limit is capped by the user's balance, matching
    /api/user/offline-limit so the app never sees two different numbers.
    """
    days_since_reg = (datetime.utcnow() - user.created_at).days if user.created_at else 0
    risk_score, _factors = compute_risk_score({
        "transaction_count": user.transaction_count,
        "avg_transaction_amount": user.avg_transaction_amount,
        "kyc_tier": user.kyc_tier,
        "device_trust_score": user.device_trust_score,
        "days_since_registration": days_since_reg,
        "fraud_flags": user.fraud_flags,
        "total_spent": user.avg_transaction_amount * user.transaction_count,
    })
    limit = min(compute_offline_limit(risk_score), user.balance)
    return limit, risk_score


@app.get("/")
def root():
    return {
        "name": "SetuPay API",
        "version": "1.0.0",
        "description": "AI-powered offline payment system",
        "docs": "/docs",
    }


@app.get("/health")
def health_check():
    return {"status": "healthy"}


@app.post("/api/admin/seed")
def seed_demo_data(db: Session = Depends(get_db)):
    """One-time seed endpoint — creates demo accounts if none exist."""
    from .models import User, UserRole, generate_uuid
    from .auth import hash_password

    if db.query(User).first():
        return {"status": "already_seeded"}

    demo_users = [
        User(id=generate_uuid(), email="alice@demo.com",
             password_hash=hash_password("password123"),
             full_name="Alice Kumar", role=UserRole.USER,
             kyc_tier=2, balance=10000.0, device_trust_score=0.85),
        User(id=generate_uuid(), email="bob@demo.com",
             password_hash=hash_password("password123"),
             full_name="Bob Singh", role=UserRole.USER,
             kyc_tier=1, balance=5000.0, device_trust_score=0.70),
        User(id=generate_uuid(), email="shopkeeper@demo.com",
             password_hash=hash_password("password123"),
             full_name="Raj Shopkeeper", role=UserRole.MERCHANT,
             kyc_tier=3, balance=50000.0, device_trust_score=0.95),
    ]
    for u in demo_users:
        db.add(u)
    db.commit()
    return {"status": "seeded", "accounts": [u.email for u in demo_users]}


@app.get("/api/public-key")
def get_public_key():
    """Get the Ed25519 public key for offline token verification."""
    from .config import PUBLIC_KEY_HEX
    return {"public_key": PUBLIC_KEY_HEX}


@app.post("/api/offline/sync")
def sync_offline_blobs(
    payload: dict,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """
    SyncEngine endpoint. Accepts an array of PaymentBlobs and reconciles each.

    Security checks per blob, evaluated in order — first hit rejects:
      1. Shape       — positive amount, timestamp inside the 72-hour window
      2. Replay      — dedup on (nonce) against settled transactions and the
                       global nonce registry            → reason `duplicate`
      3. Signature   — ECDSA P-256 over the canonical payload, verified against
                       the sender's registered device key
                       → `invalid_signature` / `unsigned_device`
                       (SIGNATURE_ENFORCEMENT=log_only records and continues;
                        `enforce` rejects)
      4. Over-limit  — NPCI per-txn ₹2,000 / daily ₹4,000, the limit the blob
                       claims it was authorised under, and the server's own
                       AI limit snapshot                → `limit_exceeded`
      5. Velocity    — > VELOCITY_MAX_BLOBS offline blobs from one sender
                       inside VELOCITY_WINDOW_MIN       → `velocity`
      6. Account     — sender exists, balance covers it
      7. Fraud       — existing multi-signal heuristics
      8. Settlement  — first-valid-wins conflict resolution

    Returns per-blob `status` (accepted | rejected | duplicate | confirmed),
    a machine-readable `reason`, and a human `reason_detail` written by the
    GenAI explainer. Also returns the recalculated offline limit for the sender.
    """
    from .models import Transaction, TransactionStatus, LedgerEntry, generate_uuid
    from .services.fraud import check_fraud_signals
    from .services.signature_verification import (
        verify_blob_signature,
        check_nonce_uniqueness,
        validate_timestamp,
        cleanup_expired_nonces,
    )
    from .services import ops_events as ops
    from .services.explainer import explain_rejection, invalidate_user
    from .config import (
        DEMO_MODE,
        SIGNATURE_ENFORCEMENT,
        VELOCITY_MAX_BLOBS,
        VELOCITY_WINDOW_MIN,
    )

    NPCI_PER_TXN_LIMIT = 2000.0
    NPCI_DAILY_LIMIT = 4000.0

    blobs = payload.get("blobs", [])
    lang = payload.get("lang", "en")
    results = []

    # Server-side AI limit snapshot for the syncing user, recomputed now
    # rather than trusting the stale `offline_limit` column.
    server_limit_snapshot, server_risk_score = _current_limit_for(current_user)

    # Track daily total for this sender across the batch
    today_start = datetime.utcnow().replace(hour=0, minute=0, second=0, microsecond=0)
    daily_total_this_batch = 0.0
    velocity_seen_in_batch: dict = {}
    # One dashboard card per (sender, rule) per batch. A burst of 8 blobs is
    # one attack on stage, not eight — the per-blob results still carry the
    # reason for every blob.
    fraud_cards: dict = {}

    def _display(user_id: str, fallback: str = "") -> str:
        if user_id == current_user.id:
            return ops.mask_user(current_user.full_name, current_user.id)
        row = db.query(User).filter(User.id == user_id).first()
        return ops.mask_user(row.full_name if row else fallback, user_id)

    def _reject(blob_id, reason, sender_id, amount, blob, *, kind="rejected",
                fraud_rule=None, extra=None):
        """Build the per-blob result, write the ops event, return the dict."""
        detail = explain_rejection(blob, reason, lang)
        item = {
            "id": blob_id,
            "status": kind,
            "reason": reason,
            "reason_detail": detail,
            # `message` is retained verbatim for older mobile builds that
            # surface it directly in the UI.
            "message": detail,
        }
        if extra:
            item.update(extra)
        sender_name = _display(sender_id)
        # One feed row per blob …
        ops.emit("rejected", blob_id=blob_id, sender=sender_name, amount=amount,
                 reason=reason, reason_detail=detail)
        # … but only one threat card per (sender, rule) per batch: a burst of
        # 8 blobs is one attack on stage, not eight.
        if fraud_rule:
            card_key = (sender_id, fraud_rule)
            if card_key in fraud_cards:
                fraud_cards[card_key]["blocked_count"] += 1
            else:
                fraud_cards[card_key] = ops.emit(
                    "fraud_flag", sender=sender_name, amount=amount,
                    rule=fraud_rule, reason=reason, detail=detail,
                    blocked_count=1,
                )
        return item

    for blob in blobs:
        blob_id = blob.get("id", generate_uuid())
        sender_id = blob.get("sender_id", "")
        receiver_id = blob.get("receiver_id", "")
        amount = float(blob.get("amount", 0) or 0)
        nonce = blob.get("nonce", generate_uuid())
        is_offline = blob.get("is_offline", True)
        timestamp_str = blob.get("timestamp", "")
        handoff_method = blob.get("handoff_method") or ("ble" if blob.get("via_ble") else "sync")

        sender_display = _display(sender_id)
        receiver_display = _display(receiver_id) if receiver_id else "—"
        blob_ctx = dict(blob)
        blob_ctx["sender_display"] = sender_display

        ops.emit("blob_received", blob_id=blob_id, sender=sender_display,
                 receiver=receiver_display, amount=amount,
                 handoff_method=handoff_method, offline=bool(is_offline))

        # ── 1. Shape ────────────────────────────────────────────
        if amount <= 0:
            results.append(_reject(blob_id, "invalid_amount", sender_id, amount, blob_ctx))
            continue

        ts_valid, ts_reason = validate_timestamp(timestamp_str)
        if not ts_valid:
            results.append(_reject(blob_id, "timestamp", sender_id, amount, blob_ctx,
                                   extra={"reason_code_detail": ts_reason}))
            continue

        # ── 2. Replay ───────────────────────────────────────────
        existing = db.query(Transaction).filter(Transaction.nonce == nonce).first()
        if existing:
            # Three different things arrive as "a nonce we already settled":
            #   - the SAME account uploading it again        -> replay attack
            #   - the OTHER participant's copy (Case 3 race,
            #     e.g. receiver synced first via QR/BLE)      -> confirmed
            #   - anyone else                                 -> duplicate
            # Older rows (before synced_by existed) fall back to the
            # participant test.
            uploader = getattr(existing, "synced_by", None)
            is_participant = current_user.id in (existing.sender_id, existing.receiver_id)
            if uploader:
                is_counterparty_copy = is_participant and current_user.id != uploader
            else:
                is_counterparty_copy = is_participant and current_user.id != existing.sender_id
            # A participant gets "confirmed" exactly once. After that we
            # stamp them as a second uploader so a further resend is a
            # replay, no matter which side it comes from.
            already_confirmed = bool(getattr(existing, "confirmed_by", None)) and \
                current_user.id in (existing.confirmed_by or "").split(",")
            if is_counterparty_copy and not already_confirmed:
                prior = existing.confirmed_by or ""
                existing.confirmed_by = f"{prior},{current_user.id}".strip(",")
                settled_at = existing.settled_at or existing.created_at
                results.append({
                    "id": blob_id,
                    "status": "confirmed",
                    "reason": "already_settled",
                    "reason_detail": (
                        f"Confirmed — this payment of ₹{amount:,.0f} was already "
                        f"settled from {sender_display}'s side."
                    ),
                    "message": "Confirmed — already settled",
                    "settled_at": settled_at.isoformat() if settled_at else None,
                })
                ops.emit("settlement_confirmed", blob_id=blob_id,
                         sender=sender_display, receiver=receiver_display,
                         amount=amount, handoff_method=handoff_method)
                continue

            blob_ctx["settled_at_display"] = _local_hhmm(existing.settled_at)
            results.append(_reject(blob_id, "duplicate", sender_id, amount, blob_ctx,
                                   kind="duplicate", fraud_rule="replay"))
            continue

        nonce_ok, nonce_reason = check_nonce_uniqueness(nonce, sender_id, amount, db)
        if not nonce_ok:
            results.append(_reject(blob_id, "duplicate", sender_id, amount, blob_ctx,
                                   kind="duplicate", fraud_rule="replay"))
            continue

        # ── 3. Signature ────────────────────────────────────────
        sig_valid, sig_reason = verify_blob_signature(blob, db)
        signature_verified = sig_valid
        if not sig_valid:
            reason = "unsigned_device" if sig_reason in ("unsigned_blob", "unsigned_device") \
                else "invalid_signature"
            if SIGNATURE_ENFORCEMENT == "enforce":
                results.append(_reject(blob_id, reason, sender_id, amount, blob_ctx,
                                       fraud_rule="signature"))
                continue
            # log_only: record it loudly, then let the blob through so a phone
            # that has not registered its key yet can still pay on stage.
            ops.emit("signature_invalid", blob_id=blob_id, sender=sender_display,
                     amount=amount, reason=reason, detail=sig_reason,
                     enforcement="log_only")

        # ── 4. Over-limit ───────────────────────────────────────
        claimed_limit = float(blob.get("offline_limit_at_time", 0) or 0)
        over_limit_reason = None
        if amount > NPCI_PER_TXN_LIMIT:
            over_limit_reason = f"per-transaction cap ₹{NPCI_PER_TXN_LIMIT:,.0f}"
        elif daily_total_this_batch + amount > NPCI_DAILY_LIMIT:
            over_limit_reason = f"daily offline cap ₹{NPCI_DAILY_LIMIT:,.0f}"
        elif is_offline and claimed_limit > 0 and amount > claimed_limit:
            over_limit_reason = f"the ₹{claimed_limit:,.0f} the blob claims it was authorised for"
        elif is_offline and sender_id == current_user.id and amount > server_limit_snapshot:
            over_limit_reason = f"the AI offline limit of ₹{server_limit_snapshot:,.0f}"

        if over_limit_reason:
            results.append(_reject(blob_id, "limit_exceeded", sender_id, amount, blob_ctx,
                                   fraud_rule="over_limit",
                                   extra={"limit_detail": over_limit_reason}))
            continue

        # ── 5. Velocity ─────────────────────────────────────────
        if is_offline:
            window_start = datetime.utcnow() - timedelta(minutes=VELOCITY_WINDOW_MIN)
            recent_history = db.query(Transaction).filter(
                Transaction.sender_id == sender_id,
                Transaction.created_at >= window_start,
            ).count()
            in_batch = velocity_seen_in_batch.get(sender_id, 0)
            if recent_history + in_batch >= VELOCITY_MAX_BLOBS:
                results.append(_reject(
                    blob_id, "velocity", sender_id, amount, blob_ctx,
                    fraud_rule="velocity",
                    extra={"velocity_detail":
                           f"{recent_history + in_batch} offline payments in "
                           f"{VELOCITY_WINDOW_MIN} min (max {VELOCITY_MAX_BLOBS})"},
                ))
                continue

        # ── 6. Account ──────────────────────────────────────────
        sender = db.query(User).filter(User.id == sender_id).first()
        if not sender:
            results.append(_reject(blob_id, "sender_not_found", sender_id, amount, blob_ctx))
            continue

        if sender.balance < amount:
            results.append(_reject(blob_id, "insufficient_balance", sender_id, amount, blob_ctx))
            continue

        # ── 7. Fraud heuristics ─────────────────────────────────
        is_suspicious, fraud_reasons = check_fraud_signals(db, sender_id, amount, nonce)
        if is_suspicious and DEMO_MODE:
            results.append(_reject(blob_id, "fraud", sender_id, amount, blob_ctx,
                                   fraud_rule="heuristics",
                                   extra={"fraud_signals": fraud_reasons}))
            continue
        if is_suspicious:
            # Outside DEMO_MODE the heuristics are advisory: flag, do not block.
            ops.emit("fraud_flag", sender=sender_display, amount=amount,
                     rule="heuristics", reason="flagged_not_blocked",
                     detail="; ".join(fraud_reasons))

        # ── 8. Settle ───────────────────────────────────────────
        sender.balance -= amount
        sender.transaction_count += 1
        total = sender.avg_transaction_amount * (sender.transaction_count - 1) + amount
        sender.avg_transaction_amount = total / sender.transaction_count
        daily_total_this_batch += amount
        velocity_seen_in_batch[sender_id] = velocity_seen_in_batch.get(sender_id, 0) + 1

        receiver = None
        if receiver_id:
            receiver = db.query(User).filter(User.id == receiver_id).first()
            if receiver:
                receiver.balance += amount

        tx = Transaction(
            id=generate_uuid(),
            token_id=nonce,
            sender_id=sender_id,
            receiver_id=receiver_id if receiver else None,
            amount=amount,
            nonce=nonce,
            device_signature=blob.get("device_signature", ""),
            status=TransactionStatus.SETTLED,
            synced_at=datetime.utcnow(),
            settled_at=datetime.utcnow(),
            synced_by=current_user.id,
        )
        db.add(tx)
        db.flush()

        db.add(LedgerEntry(
            user_id=sender_id,
            transaction_id=tx.id,
            entry_type="debit",
            amount=amount,
            balance_after=sender.balance,
        ))
        if receiver:
            db.add(LedgerEntry(
                user_id=receiver_id,
                transaction_id=tx.id,
                entry_type="credit",
                amount=amount,
                balance_after=receiver.balance,
            ))

        status_msg = "Settled (signature verified)" if signature_verified else "Settled (unsigned — legacy)"
        results.append({
            "id": blob_id,
            "status": "accepted",
            "reason": "settled",
            "reason_detail": status_msg,
            "message": status_msg,
            "signature_verified": signature_verified,
        })
        ops.emit("settled", blob_id=blob_id, sender=sender_display,
                 receiver=receiver_display, amount=amount,
                 handoff_method=handoff_method,
                 signature_verified=signature_verified)

    db.commit()

    # Periodic nonce cleanup
    try:
        cleanup_expired_nonces(db)
    except Exception:
        pass

    # Recalculate and return the new offline limit for the syncing user
    old_limit = current_user.offline_limit or 0.0
    new_limit, new_risk = _current_limit_for(current_user)
    current_user.offline_limit = new_limit
    db.commit()

    ops.note_limit(ops.mask_user(current_user.full_name, current_user.id), new_limit, new_risk)
    if abs(new_limit - old_limit) > 0.01:
        ops.emit("limit_changed",
                 user=ops.mask_user(current_user.full_name, current_user.id),
                 old_limit=old_limit, new_limit=new_limit, risk_score=new_risk)
    # The "Why this limit?" card must visibly update after a sync.
    invalidate_user(current_user.id)

    expiry = (datetime.utcnow() + timedelta(hours=24)).isoformat()

    # Sign the new limit
    from .config import SIGNING_KEY
    limit_payload = f"{current_user.id}|{new_limit:.2f}|{expiry}"
    limit_signature = SIGNING_KEY.sign(limit_payload.encode()).signature.hex()

    return {
        "results": results,
        "new_offline_limit": new_limit,
        "limit_expiry": expiry,
        "limit_signature": limit_signature,
    }


@app.post("/api/payments/online")
def make_online_payment(
    payment: dict,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """
    Case 2: Sender is online. Debit sender immediately.
    If receiver_id is provided and the receiver exists, credit them now.
    If receiver is not found or not yet synced, hold the credit as a
    pending transaction — receiver claims it when they next sync.
    """
    from .models import Transaction, TransactionStatus, LedgerEntry, generate_uuid

    receiver_id = payment.get("receiver_id")
    amount = float(payment.get("amount", 0))
    nonce = payment.get("nonce") or str(__import__("uuid").uuid4())
    receiver_name = payment.get("receiver_name", "")

    if amount <= 0:
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail="Amount must be positive")

    if current_user.balance < amount:
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail="Insufficient balance")

    # Debit sender immediately
    current_user.balance -= amount
    current_user.transaction_count += 1
    total = current_user.avg_transaction_amount * (current_user.transaction_count - 1) + amount
    current_user.avg_transaction_amount = total / current_user.transaction_count

    # Credit receiver if they exist
    receiver = None
    if receiver_id:
        receiver = db.query(User).filter(User.id == receiver_id).first()
        if receiver:
            receiver.balance += amount

    tx_status = TransactionStatus.SETTLED if receiver else TransactionStatus.PENDING_OFFLINE

    tx = Transaction(
        id=generate_uuid(),
        token_id=nonce,  # reuse token_id column to store nonce for online payments
        sender_id=current_user.id,
        receiver_id=receiver_id,
        amount=amount,
        nonce=nonce,
        status=tx_status,
        merchant_name=receiver_name,
        synced_at=datetime.utcnow(),
        settled_at=datetime.utcnow() if receiver else None,
    )
    db.add(tx)
    db.flush()

    debit = LedgerEntry(
        user_id=current_user.id,
        transaction_id=tx.id,
        entry_type="debit",
        amount=amount,
        balance_after=current_user.balance,
    )
    db.add(debit)

    if receiver:
        credit = LedgerEntry(
            user_id=receiver_id,
            transaction_id=tx.id,
            entry_type="credit",
            amount=amount,
            balance_after=receiver.balance,
        )
        db.add(credit)

    db.commit()

    from .services import ops_events as ops
    from .services.explainer import invalidate_user
    ops.emit(
        "online_payment",
        sender=ops.mask_user(current_user.full_name, current_user.id),
        receiver=ops.mask_user(
            receiver.full_name if receiver else receiver_name, receiver_id or ""
        ),
        amount=amount,
        handoff_method="online",
    )
    invalidate_user(current_user.id)

    return {
        "status": tx_status.value,
        "transaction_id": tx.id,
        "receiver_credited": receiver is not None,
        "message": "Payment sent" if receiver else "Payment sent — receiver will be credited on sync",
    }


@app.get("/api/app/version")
def get_app_version():
    """
    Returns the minimum required app version and latest available version.
    Clients must check this at startup and block usage if their version
    is below min_version (MASVS-CODE-2 compliance).
    """
    return {
        "min_version": "1.0.0",
        "min_build_number": 1,
        "latest_version": "1.0.0",
        "update_url": "https://play.google.com/store/apps/details?id=com.offlinepay",
        "update_message": None,
        "force_update": False,
    }


@app.get("/api/user/offline-limit")
def get_offline_limit(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """
    Return the user's current AI/ML-assigned offline credit limit and
    its expiry timestamp. The Flutter app caches this for 24 hours so
    payments can be authorised without a network connection.
    """
    from .services import ops_events as ops

    limit, risk_score = _current_limit_for(current_user)
    ops.note_limit(ops.mask_user(current_user.full_name, current_user.id), limit, risk_score)

    expiry = datetime.utcnow() + timedelta(hours=24)

    # Sign the limit so the client can verify it wasn't tampered with
    from .config import SIGNING_KEY
    limit_payload = f"{current_user.id}|{limit:.2f}|{expiry.isoformat()}"
    limit_signature = SIGNING_KEY.sign(limit_payload.encode()).signature.hex()

    return {
        "limit": limit,
        "expiry": expiry.isoformat(),
        "risk_score": risk_score,
        "limit_signature": limit_signature,
    }
