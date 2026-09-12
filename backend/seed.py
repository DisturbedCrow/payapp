"""
Seed script to populate the database with demo data.
Run: python seed.py           (skips if any user exists)
     python seed.py --force   (wipes users/transactions and reseeds)

The three demo-day accounts are deliberately spread across the risk model so
the dashboard's Trust Engine panel shows visibly different bars on stage:

  ashmita   KYC 3, 214 historical txns, 0 fraud flags   -> top limit tier  (STAGE SENDER)
  jyati     merchant receiver                                          (STAGE RECEIVER)
  vivek     same profile as ashmita, kept for older scripts
  ramesh    merchant receiver, kept for older scripts
  attacker  KYC 0, brand new account, 1 prior fraud flag -> floor limit tier
"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from datetime import datetime, timedelta

from app.database import SessionLocal, init_db
from app.models import (
    DeviceBinding,
    LedgerEntry,
    NonceRegistry,
    OfflineToken,
    Transaction,
    User,
    UserRole,
)
from app.auth import hash_password
from app.services.demo_ids import demo_user_id
from app.services.risk_engine import compute_offline_limit, compute_risk_score


def seed_database(force: bool = False):
    """Create demo users for the hackathon."""
    init_db()
    db = SessionLocal()

    try:
        existing = db.query(User).first()
        if existing and not force:
            print("Database already seeded. Skipping. (use --force to reseed)")
            return
        if existing and force:
            for model in (LedgerEntry, Transaction, NonceRegistry,
                          OfflineToken, DeviceBinding, User):
                db.query(model).delete()
            db.commit()
            print("Wiped existing data (--force).")

        # Demo Users
        users = [
            User(
                email="alice@demo.com",
                password_hash=hash_password("password123"),
                full_name="Alice Johnson",
                phone="+919876543210",
                role=UserRole.USER,
                kyc_tier=3,
                device_trust_score=0.85,
                balance=10000.0,
                transaction_count=45,
                avg_transaction_amount=250.0,
            ),
            User(
                email="bob@demo.com",
                password_hash=hash_password("password123"),
                full_name="Bob Smith",
                phone="+919876543211",
                role=UserRole.USER,
                kyc_tier=2,
                device_trust_score=0.65,
                balance=5000.0,
                transaction_count=12,
                avg_transaction_amount=150.0,
            ),
            User(
                email="charlie@demo.com",
                password_hash=hash_password("password123"),
                full_name="Charlie Kumar",
                phone="+919876543212",
                role=UserRole.USER,
                kyc_tier=1,
                device_trust_score=0.40,
                balance=2000.0,
                transaction_count=3,
                avg_transaction_amount=80.0,
                fraud_flags=1,
            ),
        ]

        # ── Demo-day cast (Sept 13) ────────────────────────────
        # These three drive the stage script and the attack demo.
        now = datetime.utcnow()
        demo_day = [
            # ── The pair used on stage ──────────────────────────
            User(
                id=demo_user_id("ashmita@gmail.com"),
                email="ashmita@gmail.com",
                password_hash=hash_password("password123"),
                full_name="Ashmita Rao",
                phone="+919000000011",
                role=UserRole.USER,
                kyc_tier=3,
                device_trust_score=0.95,
                balance=12000.0,
                transaction_count=214,
                avg_transaction_amount=340.0,
                fraud_flags=0,
                created_at=now - timedelta(days=420),
            ),
            User(
                id=demo_user_id("vivek@demo.com"),
                email="vivek@demo.com",
                password_hash=hash_password("password123"),
                full_name="Vivek Sharma",
                phone="+919000000001",
                role=UserRole.USER,
                kyc_tier=3,
                device_trust_score=0.95,
                balance=12000.0,
                transaction_count=214,
                avg_transaction_amount=340.0,
                fraud_flags=0,
                created_at=now - timedelta(days=420),
            ),
            User(
                id=demo_user_id("attacker@demo.com"),
                email="attacker@demo.com",
                password_hash=hash_password("password123"),
                full_name="Anon Attacker",
                phone="+919000000003",
                role=UserRole.USER,
                kyc_tier=0,
                device_trust_score=0.15,
                balance=3000.0,
                transaction_count=0,
                avg_transaction_amount=0.0,
                fraud_flags=1,
                created_at=now - timedelta(days=1),
            ),
        ]

        # Demo Merchants
        merchants = [
            # Stage receiver.
            User(
                id=demo_user_id("jyati@gmail.com"),
                email="jyati@gmail.com",
                password_hash=hash_password("password123"),
                full_name="Jyati Kirana",
                phone="+919000000012",
                role=UserRole.MERCHANT,
                kyc_tier=3,
                device_trust_score=0.92,
                balance=0.0,
                transaction_count=180,
                avg_transaction_amount=290.0,
                created_at=now - timedelta(days=380),
            ),
            User(
                id=demo_user_id("ramesh@demo.com"),
                email="ramesh@demo.com",
                password_hash=hash_password("password123"),
                full_name="Ramesh Kirana",
                phone="+919000000002",
                role=UserRole.MERCHANT,
                kyc_tier=3,
                device_trust_score=0.92,
                balance=0.0,
                transaction_count=180,
                avg_transaction_amount=290.0,
                created_at=now - timedelta(days=380),
            ),
            User(
                email="shopkeeper@demo.com",
                password_hash=hash_password("password123"),
                full_name="Ravi's General Store",
                phone="+919876543220",
                role=UserRole.MERCHANT,
                kyc_tier=2,
                device_trust_score=0.70,
                balance=0.0,
            ),
            User(
                email="chai@demo.com",
                password_hash=hash_password("password123"),
                full_name="Priya's Chai Point",
                phone="+919876543221",
                role=UserRole.MERCHANT,
                kyc_tier=2,
                device_trust_score=0.80,
                balance=0.0,
            ),
            User(
                email="pharmacy@demo.com",
                password_hash=hash_password("password123"),
                full_name="MedPlus Pharmacy",
                phone="+919876543222",
                role=UserRole.MERCHANT,
                kyc_tier=3,
                device_trust_score=0.90,
                balance=0.0,
            ),
        ]

        for user in users + demo_day + merchants:
            db.add(user)

        db.commit()

        # Materialise each user's AI limit so the Trust Engine panel has bars
        # before the first payment of the demo.
        for user in db.query(User).all():
            days = (datetime.utcnow() - user.created_at).days if user.created_at else 0
            risk, _ = compute_risk_score({
                "transaction_count": user.transaction_count,
                "avg_transaction_amount": user.avg_transaction_amount,
                "kyc_tier": user.kyc_tier,
                "device_trust_score": user.device_trust_score,
                "days_since_registration": days,
                "fraud_flags": user.fraud_flags,
                "total_spent": user.avg_transaction_amount * user.transaction_count,
            })
            user.offline_limit = min(compute_offline_limit(risk), user.balance)
        db.commit()

        print(f"Seeded {len(users) + len(demo_day)} users and {len(merchants)} merchants.")
        print("\nDemo Credentials:")
        print("  Users:")
        print("    alice@demo.com / password123  (High trust, KYC 3)")
        print("    bob@demo.com / password123    (Medium trust, KYC 2)")
        print("    charlie@demo.com / password123 (Low trust, KYC 1, 1 fraud flag)")
        print("  Demo-day cast:")
        for u in db.query(User).order_by(User.offline_limit.desc()).all():
            print(f"    {u.email:<24} limit ₹{u.offline_limit:>7,.0f}  "
                  f"kyc {u.kyc_tier}  flags {u.fraud_flags}  txns {u.transaction_count}")
        print("  Merchants:")
        print("    jyati@gmail.com / password123  (STAGE RECEIVER)")
        print("    ramesh@demo.com / password123")
        print("    shopkeeper@demo.com / password123")
        print("    chai@demo.com / password123")
        print("    pharmacy@demo.com / password123")

    finally:
        db.close()


if __name__ == "__main__":
    seed_database(force="--force" in sys.argv)
