# SetuPay

**Offline-first payments with an AI trust layer.** *Setu* (सेतु) means "bridge" — SetuPay bridges the gap when the network drops. Payments work without internet via AI-assigned local credit limits, signed payment blobs, QR or BLE device-to-device transfer, and background sync when connectivity returns. It integrates with any UPI app (Paytm, PhonePe, GPay) as an additive SDK layer rather than replacing them.

---

## Table of Contents

- [Concept](#concept)
- [Architecture](#architecture)
- [Payment Cases](#payment-cases)
- [Offline Credit Limit & ML Model](#offline-credit-limit--ml-model)
- [Sync Engine](#sync-engine)
- [Project Structure](#project-structure)
- [Tech Stack](#tech-stack)
- [Backend API Reference](#backend-api-reference)
- [Running Locally](#running-locally)
- [Deployment](#deployment)
- [Installing the App](#installing-the-app)
- [Presentation](#presentation)

---

## What we built on Sept 13 (AI hackathon sprint)

Everything below is new work from the demo sprint, on the `demo-day` branch. Each
feature is behind a flag (`mobile/lib/config/constants.dart`, `backend/app/config.py`)
so the three original payment cases keep working untouched.

| | Feature | Where |
|---|---|---|
| **B** | **Real device signing end-to-end.** The canonical signing payload now lives in one place per side (`backend/app/services/signing.py`, `canonicalPayload()` in `payment_blob.dart`) with a shared cross-language test vector. Every offline blob is signed with the device's ECDSA P-256 key and verified at sync against the *registered* device binding. `SIGNATURE_ENFORCEMENT=log_only\|enforce`. | `backend/app/services/signing.py`, `mobile/lib/models/payment_blob.dart` |
| **C** | **Signed-blob-in-QR handoff ("Case 3b").** Both phones in airplane mode: the sender renders the signed blob as a QR, the receiver scans and verifies the signature *locally, offline*. De-risks BLE on a stage with 150 phones. The backend's dedup collapses the sender's and receiver's copies into one settlement and answers the second copy with `confirmed`, not a scary rejection. | `mobile/lib/screens/qr_handoff_screen.dart`, `receive_scan_screen.dart` |
| **D** | **GenAI risk explainer.** Turns the sklearn model's feature vector into plain English or Hinglish: *"Your offline limit is ₹1,500 because your KYC is verified to tier 2 and 3 payments are still waiting to sync."* Mock templates are the always-present fallback (<1 ms, no key needed); Claude is used when `EXPLAINER_PROVIDER=anthropic`, with a 2-second timeout and silent degradation. | `backend/app/services/explainer.py`, `GET /api/user/limit-explanation` |
| **E** | **Live ops dashboard for the projector.** A dark, self-contained page polling every 2 s that shows payments arriving, settlements, AI limits recalculating, and attacks being blocked with the explainer's own words. | `GET /dashboard/live?token=...` |
| **F** | **Fraud rules + red-team CLI.** Replay, forged-signature, over-limit and velocity rules, each returning a machine reason and a human `reason_detail`. `python -m demo.attack all` runs the four attacks from a terminal and exits non-zero if any succeeds — a security regression test that doubles as a demo beat. | `backend/demo/attack.py` |
| **G** | **Hindi/Hinglish voice payments, fully offline.** *"Ramesh ko do sau rupaye bhejo"* → confirm screen → the existing offline payment path. Intent parsing is pure Dart (regex + Hindi number-word composition), so it works in airplane mode. | `mobile/lib/services/voice_intent_parser.dart` |
| **A** | **Rebrand to SetuPay** — original product identity, deep indigo + saffron, positioned as a UPI-app SDK rather than a wallet clone. | throughout |

Run the demo: `backend/run_local.sh`, then `presentation/DEMO_RUNBOOK.md`.

---

## Concept

Traditional UPI payments fail the moment internet drops. This project decouples **payment capture** from **payment settlement**:

- Every user has an **AI-assigned offline credit limit** (₹0–₹5,000), cached on-device
- Payments within this limit are captured locally as **payment blobs**
- Blobs sync to the backend when connectivity is restored, where the backend settles and reconciles them
- A local **risk penalty** is applied immediately after each offline payment, so the displayed limit adjusts without needing a server round-trip

---

## Architecture

```
┌────────────────────────────────────────────────────┐
│                  Flutter App                        │
│                                                     │
│  ConnectivityService (stream)                       │
│       ↓ online / offline                            │
│  ┌─────────────┐    ┌──────────────────────────┐   │
│  │ Online path │    │ Offline path              │   │
│  │ HTTP → API  │    │ PaymentBlob → SQLite      │   │
│  └─────────────┘    │ OfflineLimitService       │   │
│                     │ BLEService (Case 3)       │   │
│                     └──────────────────────────┘   │
│                              ↓                      │
│                    SyncEngine (background)          │
│                    POST /api/offline/sync           │
└────────────────────────────────────────────────────┘
                            ↕ HTTPS
┌────────────────────────────────────────────────────┐
│              FastAPI Backend (Python)               │
│                                                     │
│  Auth (JWT + Ed25519)                               │
│  Token issuance → ML limit calculation              │
│  POST /api/offline/sync → dedup + settle            │
│  GET  /api/user/offline-limit → ML score → limit   │
│                                                     │
│  PostgreSQL (Render)                                │
└────────────────────────────────────────────────────┘
```

---

## Payment Cases

### Case 1 — Sender Offline, Receiver Online

```
Sender (offline)                     Receiver (online)
     │                                      │
     │── Scan QR (receiverId) ──────────────│
     │── Check offline limit locally        │
     │── Deduct from limit (SharedPrefs)    │
     │── Create PaymentBlob (SQLite)        │
     │── Apply risk penalty locally         │
     │── Show "Payment sent (offline)"      │
     │                                      │
     │   [Device comes online]              │
     │── SyncEngine → POST /offline/sync ──▶│
     │                    Backend settles ──▶ Receiver notified
```

### Case 2 — Sender Online, Receiver Offline

```
Sender (online)                      Receiver (offline)
     │                                      │
     │── Scan QR ────────────────────────── │
     │── POST /api/payments/online ────────▶│
     │   Bank debited immediately           │
     │   Backend holds credit for receiver  │
     │                                      │
     │              [Receiver comes online] │
     │              SyncEngine ────────────▶│
     │              Fetch pending credits   │
     │              Update balance + notify │
```

### Case 3 — Both Offline (BLE)

```
Sender (offline)                     Receiver (offline)
     │                                      │
     │   Receiver generates BLE session UUID│
     │   UUID embedded in QR code           │
     │── Scan QR (receiverId + bleUUID) ────│
     │── Create PaymentBlob                 │
     │── BLE scan for UUID ────────────────▶│
     │── GATT connect ─────────────────────▶│
     │── Write blob JSON (chunked) ─────────│
     │                        Store in SQLite│
     │                        Show ₹X received│
     │── Mark as sent_via_ble               │
     │── Deduct from local limit            │
     │                                      │
     │   [Either party comes online]        │
     │── POST /api/offline/sync             │
     │   Backend deduplicates by            │
     │   (senderId+receiverId+nonce+ts)     │
```

**BLE implementation:**
- **Receiver (peripheral):** Native `CBPeripheralManager` (iOS) / `BluetoothGattServer` (Android) exposed to Flutter via `MethodChannel` + `EventChannel`
- **Sender (central):** `flutter_blue_plus` scans for the session UUID, connects, writes blob in ≤512-byte chunks

---

## Offline Credit Limit & ML Model

### On-device

| Store | Key | Value |
|-------|-----|-------|
| SharedPreferences | `offline_limit` | Total limit (double) |
| SharedPreferences | `offline_limit_remaining` | Available limit (double) |
| SharedPreferences | `offline_limit_expiry` | ISO8601 expiry (24h TTL) |

After each offline payment:
1. `deductFromLimit(amount)` — decrements `offline_limit_remaining`
2. `applyLocalRiskPenalty(pendingCount)` — reduces effective cap by 10% per pending blob, floored at 30% of total
3. `WalletProvider.loadCachedTokens()` — reloads from SharedPrefs so UI updates immediately

### Backend ML model (`backend/app/ml/model.py`)

Scoring features:

| Feature | Direction |
|---------|-----------|
| `transaction_count_last_30_days` | ↑ higher limit |
| `avg_transaction_value` | ↑ higher limit |
| `account_age_days` | ↑ higher limit |
| `kyc_tier` (0–3) | ↑ higher limit |
| `fraud_flags` | ↓ lower limit |
| `device_trust_score` | ↑ higher limit |

Output: risk score (0.0–1.0) → mapped to limit tier:

| Risk Score | Limit |
|------------|-------|
| < 0.2 | ₹5,000 |
| 0.2–0.4 | ₹3,000 |
| 0.4–0.6 | ₹1,500 |
| 0.6–0.8 | ₹500 |
| 0.8–0.9 | ₹100 |
| ≥ 0.9 | ₹0 (restricted) |

Limit is recalculated and pushed to the device after every successful sync.

---

## Sync Engine

`mobile/lib/services/sync_engine.dart` runs as a background monitor:

1. Watches `ConnectivityService` stream
2. On connectivity restored → `SyncService.syncPendingTransactions()`
3. `POST /api/offline/sync` with all `pending_sync` blobs
4. Backend response per blob: `accepted` / `rejected` / `adjusted`
5. On `accepted` → mark blob `synced`, deduct from actual bank balance
6. On `rejected` → reverse local limit deduction, notify user
7. After sync → `OfflineLimitService.fetchAndCacheLimit()` pulls recalculated ML limit
8. `WalletProvider` reloads from SharedPrefs → UI updates

Backend deduplicates using composite key: `(sender_id, receiver_id, nonce, timestamp)`

---

## Project Structure

```
payapp_/
├── mobile/                          # Flutter app
│   ├── lib/
│   │   ├── main.dart
│   │   ├── config/
│   │   │   ├── constants.dart
│   │   │   └── theme.dart           # SetuPay brand palette (indigo + saffron)
│   │   ├── models/
│   │   │   ├── payment_blob.dart    # Core offline payment unit
│   │   │   ├── payment_token.dart
│   │   │   ├── transaction.dart
│   │   │   └── user.dart
│   │   ├── providers/
│   │   │   ├── auth_provider.dart
│   │   │   ├── wallet_provider.dart  # Offline limit, tokens, connectivity
│   │   │   └── transaction_provider.dart
│   │   ├── services/
│   │   │   ├── ble_service.dart      # BLE central (sender) via flutter_blue_plus
│   │   │   ├── connectivity_service.dart
│   │   │   ├── offline_limit_service.dart
│   │   │   ├── offline_queue_service.dart  # SQLite blob queue
│   │   │   ├── offline_storage.dart
│   │   │   ├── qr_transfer.dart
│   │   │   ├── sync_engine.dart
│   │   │   ├── sync_service.dart
│   │   │   └── token_service.dart
│   │   ├── screens/
│   │   │   ├── home_screen.dart
│   │   │   ├── login_screen.dart
│   │   │   ├── register_screen.dart
│   │   │   ├── show_qr_screen.dart   # BLE peripheral + QR display
│   │   │   ├── payment_receipt_screen.dart
│   │   │   ├── splash_screen.dart
│   │   │   ├── user/
│   │   │   │   ├── user_dashboard.dart
│   │   │   │   └── pay_screen.dart
│   │   │   └── merchant/
│   │   │       └── merchant_dashboard.dart
│   │   └── widgets/
│   │       └── transaction_tile.dart
│   ├── ios/
│   │   └── Runner/
│   │       ├── AppDelegate.swift     # BLE peripheral (iOS) via CBPeripheralManager
│   │       └── Info.plist            # BLE permissions
│   ├── android/
│   │   └── app/src/main/kotlin/.../
│   │       └── MainActivity.kt       # BLE peripheral (Android) via BluetoothGattServer
│   ├── SetuPay-demo-day.apk          # Demo-day APK (Android)
│   └── PaytmOfflinePay.ipa           # Pre-rebrand iOS build (kept for reference)
│
├── backend/                          # FastAPI server
│   ├── app/
│   │   ├── main.py
│   │   ├── models.py                 # SQLAlchemy models
│   │   ├── schemas.py
│   │   ├── database.py
│   │   ├── config.py
│   │   ├── routes/
│   │   │   ├── auth_routes.py        # Register, login, profile
│   │   │   ├── token_routes.py       # Offline token issuance
│   │   │   ├── sync_routes.py        # POST /api/offline/sync
│   │   │   └── dashboard.py          # User/merchant dashboards
│   │   ├── ml/
│   │   │   ├── model.py              # Risk scoring → limit calculation
│   │   │   └── train_model.py
│   │   └── services/
│   ├── requirements.txt
│   ├── seed.py                       # Demo data seeding
│   └── risk_model.joblib             # Trained sklearn model
│
├── presentation/
│   ├── slides.md                     # 15-slide Slidev presentation
│   ├── SetuPay_Slides.pdf            # Exported PDF
│   └── assets/
│       ├── diagrams/                 # Mermaid architecture PNGs
│       │   ├── arch.png
│       │   ├── case1.png
│       │   ├── case2.png
│       │   ├── case3.png
│       │   ├── ml.png
│       │   ├── security.png
│       │   └── sync.png
│       └── screens/                  # App mockup screenshots
│           ├── home_screen.png
│           ├── receipt_screen.png
│           └── qr_screen.png
│
├── render.yaml                       # Render.com deployment config
└── runtime.txt                       # Python 3.11.9
```

---

## Tech Stack

### Mobile (Flutter)

| Package | Version | Purpose |
|---------|---------|---------|
| `provider` | ^6.1.1 | State management |
| `flutter_blue_plus` | ^1.31.0 | BLE central (sender scanning) |
| `sqflite` | ^2.3.0 | Local SQLite — blob queue + transactions |
| `shared_preferences` | ^2.2.2 | Offline limit cache (24h TTL) |
| `connectivity_plus` | ^5.0.2 | Stream-based online/offline detection |
| `mobile_scanner` | ^4.0.0 | QR code scanning |
| `qr_flutter` | ^4.1.0 | QR code generation |
| `uuid` | ^4.2.1 | Blob and nonce generation |
| `path_provider` | ^2.1.1 | SQLite file path |

BLE peripheral (advertising) is implemented natively:
- **iOS:** `CBPeripheralManager` in `AppDelegate.swift`, registered via `FlutterPluginRegistry`
- **Android:** `BluetoothGattServer` + `BluetoothLeAdvertiser` in `MainActivity.kt`

Both expose the same `MethodChannel("com.offlinepay/ble_peripheral")` + `EventChannel("com.offlinepay/ble_peripheral_events")` interface to Dart.

### Backend (Python)

| Package | Version | Purpose |
|---------|---------|---------|
| `fastapi` | 0.104.1 | API framework |
| `uvicorn` | 0.24.0 | ASGI server |
| `sqlalchemy` | 2.0.23 | ORM |
| `psycopg2-binary` | 2.9.9 | PostgreSQL driver |
| `python-jose` | 3.3.0 | JWT auth |
| `PyNaCl` | 1.5.0 | Ed25519 signing |
| `scikit-learn` | 1.3.2 | ML risk model |
| `pydantic` | 2.5.2 | Request/response schemas |

---

## Backend API Reference

### Auth

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/auth/register` | Register new user |
| `POST` | `/api/auth/login` | Login, returns JWT |
| `GET` | `/api/auth/profile` | Get current user profile |
| `PUT` | `/api/auth/profile` | Update profile |

### Tokens & Limits

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/tokens/request` | Issue offline payment tokens |
| `GET` | `/api/user/offline-limit` | Get ML-calculated limit + expiry |

### Offline Sync

| Method | Endpoint | Description |
|--------|----------|-------------|
| `POST` | `/api/offline/sync` | Submit blob array; returns status per blob |

**Request:**
```json
{
  "blobs": [
    {
      "id": "uuid",
      "sender_id": "string",
      "receiver_id": "string",
      "amount": 250.0,
      "timestamp": "2026-03-30T10:00:00Z",
      "nonce": "uuid",
      "device_signature": "string",
      "is_offline": true,
      "offline_limit_at_time": 1500.0
    }
  ]
}
```

**Response:**
```json
{
  "results": [
    { "id": "uuid", "status": "accepted" },
    { "id": "uuid", "status": "rejected", "reason": "duplicate" }
  ],
  "new_offline_limit": 1250.0
}
```

### Dashboards

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/api/dashboard/user` | Balance, recent transactions, offline limit |
| `GET` | `/api/dashboard/merchant` | Earnings, received payments |

---

## Running Locally

### Backend

```bash
cd backend
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt

# Set environment variables
export SECRET_KEY=your-secret-key
export ED25519_PRIVATE_KEY_B64=your-base64-key
export DATABASE_URL=sqlite:///./offline_pay.db   # or PostgreSQL URL

uvicorn app.main:app --reload
# API runs at http://localhost:8000
# Docs at http://localhost:8000/docs
```

Seed demo data:
```bash
python seed.py
```

### Flutter App

```bash
cd mobile
flutter pub get
flutter run                    # debug on connected device
flutter run --release          # release mode
```

Update the API base URL in `lib/config/constants.dart`:
```dart
static const String apiBaseUrl = 'http://localhost:8000';
```

---

## Deployment

Deployed on **Render.com** (free tier, Singapore region).

`render.yaml` provisions:
- Web service: FastAPI via uvicorn
- PostgreSQL database

```bash
# Trigger a deploy
git push origin main
```

Environment variables to set in Render dashboard:
- `SECRET_KEY` — JWT signing secret
- `ED25519_PRIVATE_KEY_B64` — Base64-encoded Ed25519 private key for blob signing

---

## Installing the App

### Android

1. Enable **Install unknown apps** in device settings
2. Transfer `mobile/SetuPay-demo-day.apk` to device
3. Tap the file to install

Or via ADB:
```bash
adb install mobile/SetuPay-demo-day.apk
```

### iOS

The IPA is signed with a development certificate (no App Store distribution cert).

**Via Xcode:**
1. Open Xcode → Window → Devices and Simulators
2. Select your device
3. Drag `mobile/PaytmOfflinePay.ipa` onto the Installed Apps list

**Via xcrun:**
```bash
xcrun devicectl device install app --device <UDID> mobile/PaytmOfflinePay.ipa
```

**Via AltStore / Sideloadly:** Import `PaytmOfflinePay.ipa` directly.

> **BLE on iOS:** On first launch, iOS will request Bluetooth permission. Tap **Allow**. If the prompt never appeared, go to Settings → Privacy & Security → Bluetooth → enable OfflinePay.

> **BLE on Android:** On Android 12+, grant **Nearby devices** permission when prompted. If denied, go to Settings → Apps → OfflinePay → Permissions → Nearby devices → Allow.

---

## Presentation

A 15-slide Slidev presentation is in `presentation/`:

```bash
cd presentation
npm install
npm run dev          # live preview at localhost:3030
```

Or open the exported PDF directly: `presentation/SetuPay_Slides.pdf`

**Slides cover:**
1. Cover — market stats (₹18.4L Cr UPI volume, 500M users)
2. Problem — 4G reliability, rural connectivity, revenue loss
3. Solution — three-tier offline architecture
4. System Architecture diagram
5. App Demo — home screen, offline limit badge
6–8. Cases 1, 2, 3 — sequence diagrams
9. ML Engine — feature scoring, limit tiers
10. Security — Ed25519 signing, nonce replay protection
11. Sync Engine — settlement flow
12. Live App — screenshots
13. Paytm Integration — SDK hooks, rollout plan
14. Business Impact — stat cards, competitive comparison
15. Roadmap & Team

---

## PaymentBlob Schema

The core data structure passed between sender, receiver, and backend:

```dart
class PaymentBlob {
  final String id;              // UUID v4
  final String senderId;
  final String receiverId;
  final double amount;
  final DateTime timestamp;
  final String nonce;           // UUID v4 — replay protection
  final String deviceSignature; // Ed25519 placeholder
  final String status;          // pending_sync | synced | rejected
  final bool isOffline;
  final double offlineLimitAtTime; // limit available when payment was made
}
```

Deduplication key on backend: `(sender_id, receiver_id, nonce, timestamp)`
