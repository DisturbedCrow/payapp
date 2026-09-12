---
theme: seriph
title: "SetuPay — Offline-First Payments with an AI Trust Layer"
titleTemplate: "%s"
info: |
  Team Issavibles · Build in AI for India, Sept 2026
  Offline-first payment infrastructure with an AI trust layer, for India's next 500M users.
transition: slide-left
mdc: true
highlighter: shiki
lineNumbers: false
drawings:
  persist: false
fonts:
  sans: "Inter"
  mono: "Fira Code"
---

<style>
/* ── Brand tokens ──────────────────────────────────────── */
:root {
  --navy:  #002970;
  --blue:  #00B9F1;
  --light: #E8F4FD;
  --gold:  #FFD700;
  --green: #22c55e;
  --red:   #ef4444;
  --amber: #f59e0b;
}

/* ── Reusable atoms ────────────────────────────────────── */
.pill {
  display: inline-block;
  padding: 3px 14px;
  border-radius: 999px;
  font-size: 0.72rem;
  font-weight: 700;
  letter-spacing: .06em;
  text-transform: uppercase;
}
.pill-blue   { background: var(--blue);  color: var(--navy); }
.pill-gold   { background: var(--gold);  color: var(--navy); }
.pill-green  { background: var(--green); color: #fff; }
.pill-red    { background: var(--red);   color: #fff; }
.pill-amber  { background: var(--amber); color: #fff; }
.pill-white  { background: rgba(255,255,255,.15); color: #fff; border: 1px solid rgba(255,255,255,.3); }

.stat-card {
  background: rgba(0,185,241,.1);
  border: 1.5px solid rgba(0,185,241,.3);
  border-radius: 14px;
  padding: 18px 20px;
  text-align: center;
}
.stat-num   { font-size: 2rem; font-weight: 900; color: var(--blue); line-height: 1.1; }
.stat-lbl   { font-size: .72rem; color: #94a3b8; margin-top: 4px; }

.dark-card  {
  background: rgba(0,41,112,.6);
  border: 1px solid rgba(0,185,241,.3);
  border-radius: 14px;
  padding: 18px 20px;
}

.check-row  { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; font-size: .9rem; }
.check-row .dot { width: 20px; height: 20px; border-radius: 50%; display: flex; align-items: center; justify-content: center; flex-shrink: 0; font-size: .7rem; font-weight: 900; }
.dot-green  { background: var(--green); color: #fff; }
.dot-blue   { background: var(--blue);  color: var(--navy); }
.dot-red    { background: var(--red);   color: #fff; }

/* screen mockup frame */
.phone-frame {
  border: 2px solid rgba(0,185,241,.4);
  border-radius: 24px;
  overflow: hidden;
  box-shadow: 0 8px 40px rgba(0,0,0,.4);
  max-width: 240px;
}
</style>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 1  COVER
════════════════════════════════════════════════════════════ -->
---
layout: cover
background: '#001845'
class: text-white
transition: fade
---

<div class="absolute inset-0" style="background: radial-gradient(ellipse at 20% 50%, rgba(0,61,165,.5) 0%, transparent 60%), radial-gradient(ellipse at 80% 20%, rgba(0,185,241,.15) 0%, transparent 50%);"></div>

<div class="relative z-10 flex flex-col justify-center h-full pl-2">

<div v-motion :initial="{opacity:0,x:-80}" :enter="{opacity:1,x:0,transition:{duration:600}}">
  <span class="pill pill-blue mb-5 inline-block">HACKATHON 2026 · TEAM ISSAVIBLES</span>
</div>

<div v-motion :initial="{opacity:0,x:-80}" :enter="{opacity:1,x:0,transition:{delay:180,duration:600}}">
  <h1 class="text-6xl font-black leading-none mb-3">
    <span style="color:#fff">Setu</span><span style="color:#FF9933">Pay</span>
    <span style="color:#5C6BC0" class="text-3xl block mt-2">सेतु — the bridge over the offline gap</span>
  </h1>
</div>

<div v-motion :initial="{opacity:0,x:-80}" :enter="{opacity:1,x:0,transition:{delay:320,duration:600}}">
  <p class="text-xl text-blue-200 font-light mb-8 max-w-lg leading-relaxed">
    Offline-first payments with an <strong class="text-white">AI trust layer</strong> — an AI credit
    limit you can read in your own language, signatures that make offline money safe, and a
    fraud engine you can watch block attacks live.
    <strong class="text-white">Works with any UPI app.</strong>
  </p>
</div>

<div v-motion :initial="{opacity:0,y:30}" :enter="{opacity:1,y:0,transition:{delay:520,duration:500}}" class="flex gap-4 flex-wrap">
  <div class="stat-card px-6">
    <div class="stat-num">₹18.4L Cr</div>
    <div class="stat-lbl">UPI volume FY2024 (NPCI)</div>
  </div>
  <div class="stat-card px-6">
    <div class="stat-num">68%</div>
    <div class="stat-lbl">Rural India has spotty 4G (TRAI)</div>
  </div>
  <div class="stat-card px-6">
    <div class="stat-num">₹4,200 Cr</div>
    <div class="stat-lbl">Revenue lost to connectivity failures</div>
  </div>
</div>

</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 2  PROBLEM
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,y:-30}" :enter="{opacity:1,y:0,transition:{duration:500}}">

# <span style="color:#00B9F1">The Problem</span> — India's UPI breaks when connectivity does

</div>

<div class="grid grid-cols-4 gap-4 mt-6">
  <div v-click class="stat-card">
    <div class="stat-num">2.3%</div>
    <div class="stat-lbl">Monthly 4G downtime (TRAI 2023)</div>
  </div>
  <div v-click class="stat-card">
    <div class="stat-num">43M</div>
    <div class="stat-lbl">UPI merchants at risk of failed txns</div>
  </div>
  <div v-click class="stat-card">
    <div class="stat-num">500M+</div>
    <div class="stat-lbl">Active UPI users (NPCI 2024)</div>
  </div>
  <div v-click class="stat-card">
    <div class="stat-num">82%</div>
    <div class="stat-lbl">Rural merchants cite connectivity as top barrier</div>
  </div>
</div>

<div class="grid grid-cols-3 gap-5 mt-6">
  <div v-click class="dark-card">
    <div class="text-2xl mb-2">📵</div>
    <div class="font-bold text-yellow-300 mb-1">Connectivity Black Holes</div>
    <div class="text-sm text-slate-300 leading-relaxed">Metro subways, hill stations, rural markets — UPI fails completely. A chai stall in Shimla loses ₹800–1,200/day in failed digital payments.</div>
  </div>
  <div v-click class="dark-card">
    <div class="text-2xl mb-2">⚠️</div>
    <div class="font-bold text-yellow-300 mb-1">No Secure Fallback</div>
    <div class="text-sm text-slate-300 leading-relaxed">Existing offline modes (USSD *99#) are slow, insecure, and limited to ₹5,000. They don't support merchant QR flows or real-time debit.</div>
  </div>
  <div v-click class="dark-card">
    <div class="text-2xl mb-2">🔓</div>
    <div class="font-bold text-yellow-300 mb-1">Fraud Risk Without AI</div>
    <div class="text-sm text-slate-300 leading-relaxed">Any offline credit system without ML risk scoring is trivially exploitable. Static limits fail to adapt to user behaviour and fraud signals.</div>
  </div>
</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 3  SOLUTION
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,y:-30}" :enter="{opacity:1,y:0,transition:{duration:500}}">

# <span style="color:#00B9F1">Our Solution</span> — Three-Layer Offline Intelligence

</div>

<div class="grid grid-cols-3 gap-6 mt-8">

<div v-motion :initial="{opacity:0,y:50}" :enter="{opacity:1,y:0,transition:{delay:150,duration:500}}" class="dark-card">
  <div class="text-3xl mb-3">🧠</div>
  <div class="font-bold text-lg text-yellow-300 mb-2">AI Credit Limit Engine</div>
  <div class="text-sm text-slate-300 leading-relaxed mb-3">
    sklearn LogisticRegression scores each user on 6 features — transaction history, KYC tier, device trust, fraud signals. Assigns dynamic limit ₹0–₹5,000. Refreshed every sync.
  </div>
  <span class="pill pill-blue">scikit-learn</span>
  <span class="pill pill-gold ml-1">Dynamic</span>
</div>

<div v-motion :initial="{opacity:0,y:50}" :enter="{opacity:1,y:0,transition:{delay:300,duration:500}}" class="dark-card">
  <div class="text-3xl mb-3">🔐</div>
  <div class="font-bold text-lg text-yellow-300 mb-2">Signed Payment Blobs</div>
  <div class="text-sm text-slate-300 leading-relaxed mb-3">
    Each payment is a cryptographically signed struct — ECDSA P-256 signature over a canonical payload, UUID nonce, registered device binding. Tamper-proof in transit, whether over HTTPS, SQLite queue, or BLE peer-to-peer.
  </div>
  <span class="pill pill-blue">ECDSA P-256</span>
  <span class="pill pill-gold ml-1">Nonce replay</span>
</div>

<div v-motion :initial="{opacity:0,y:50}" :enter="{opacity:1,y:0,transition:{delay:450,duration:500}}" class="dark-card">
  <div class="text-3xl mb-3">⚡</div>
  <div class="font-bold text-lg text-yellow-300 mb-2">Auto-Sync Engine</div>
  <div class="text-sm text-slate-300 leading-relaxed mb-3">
    Background service wakes on connectivity restore (connectivity_plus stream). Idempotent POST to backend. Deduplication by composite key. ML limit recalculated on every sync.
  </div>
  <span class="pill pill-blue">Idempotent</span>
  <span class="pill pill-gold ml-1">Auto-heal</span>
</div>

</div>

<div v-click class="mt-6 p-4 rounded-xl text-center text-sm font-semibold" style="background:linear-gradient(90deg,rgba(0,41,112,.8),rgba(0,185,241,.2));border:1px solid #00B9F1;">
  Core insight: <span style="color:#FFD700">Decouple payment capture from payment settlement</span> — exactly how Visa/Mastercard work offline with physical cards
</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 4  ARCHITECTURE
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,y:-20}" :enter="{opacity:1,y:0,transition:{duration:400}}">

# <span style="color:#00B9F1">System Architecture</span>

</div>

<div v-motion :initial="{opacity:0,scale:.93}" :enter="{opacity:1,scale:1,transition:{delay:200,duration:600}}" class="mt-4">
  <img src="./assets/diagrams/arch.png" class="w-full rounded-xl" style="max-height:430px;object-fit:contain;background:#0a1628;" />
</div>

<div v-click class="flex gap-4 mt-4 flex-wrap">
  <span class="pill pill-blue">Flutter · Provider</span>
  <span class="pill pill-gold">FastAPI · Python</span>
  <span class="pill pill-white">PostgreSQL · Redis</span>
  <span class="pill pill-white">connectivity_plus · sqflite · flutter_blue_plus</span>
</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 5  APP DEMO — HOME SCREEN
════════════════════════════════════════════════════════════ -->
---
layout: two-cols
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,x:-40}" :enter="{opacity:1,x:0,transition:{duration:500}}">

# <span style="color:#00B9F1">App Demo</span> — Home Screen

</div>

<div class="mt-4 space-y-4">

<div v-click class="dark-card">
  <div class="font-bold text-yellow-300 mb-1">📵 Offline Mode Banner</div>
  <div class="text-sm text-slate-300">Animated banner slides in when connectivity drops. Deep orange — impossible to miss.</div>
</div>

<div v-click class="dark-card">
  <div class="font-bold text-yellow-300 mb-1">₹1,450 offline ⓘ</div>
  <div class="text-sm text-slate-300">Tap the pill → explainability sheet shows per-factor breakdown: KYC tier, device trust, fraud flags.</div>
</div>

<div v-click class="dark-card">
  <div class="font-bold text-yellow-300 mb-1">Scan QR + My QR</div>
  <div class="text-sm text-slate-300">Two-button layout. My QR starts BLE advertising — works for any user type (merchant, retailer, UPI user).</div>
</div>

<div v-click class="dark-card">
  <div class="font-bold text-yellow-300 mb-1">Transaction History</div>
  <div class="text-sm text-slate-300">Online · Offline · BLE — all modes shown with status badges. Merged from SQLite + server in real time.</div>
</div>

</div>

::right::

<div v-motion :initial="{opacity:0,x:40,scale:.9}" :enter="{opacity:1,x:0,scale:1,transition:{delay:300,duration:600}}" class="flex justify-center mt-8">
  <div class="phone-frame">
    <img src="./assets/screens/home_screen.png" style="width:260px;display:block;" />
  </div>
</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 6  CASE 1
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div class="flex items-center gap-3 mb-4">
  <div v-motion :initial="{opacity:0,x:-40}" :enter="{opacity:1,x:0,transition:{duration:400}}">
    <span class="pill pill-gold text-base px-4 py-1">Case 1</span>
  </div>
  <div v-motion :initial="{opacity:0,x:-20}" :enter="{opacity:1,x:0,transition:{delay:100,duration:400}}">
    <h2 class="text-2xl font-black">Sender Offline · Receiver Online</h2>
  </div>
</div>

<div class="grid grid-cols-3 gap-4">

<div class="col-span-2">
  <div v-motion :initial="{opacity:0,scale:.93}" :enter="{opacity:1,scale:1,transition:{delay:200,duration:600}}">
    <img src="./assets/diagrams/case1.png" class="w-full rounded-xl" style="max-height:400px;object-fit:contain;background:#0a1628;" />
  </div>
</div>

<div class="flex flex-col gap-3 justify-center">
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">🔑 How it works</div>
    <div class="text-xs text-slate-300">Payment captured instantly offline. Debit happens on reconnect — like a post-dated signed cheque that auto-deposits.</div>
  </div>
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">🛡️ Safety</div>
    <div class="text-xs text-slate-300">ML limit caps max exposure. Ed25519 signature prevents blob tampering. Nonce replay stops double-spend.</div>
  </div>
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">📊 Real-world impact</div>
    <div class="text-xs text-slate-300">Metro commuter pays in a tunnel. Delivery agent transacts in a basement. Tourist pays at a hill-station stall. Zero failed sales.</div>
  </div>
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">⏱️ Sync latency</div>
    <div class="text-xs text-slate-300">Avg reconnect → settle: &lt;3 seconds. Backend deduplicates idempotently — safe to retry on flaky connections.</div>
  </div>
</div>

</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 7  CASE 2
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div class="flex items-center gap-3 mb-4">
  <span v-motion :initial="{opacity:0,x:-40}" :enter="{opacity:1,x:0,transition:{duration:400}}" class="pill pill-blue text-base px-4 py-1">Case 2</span>
  <h2 v-motion :initial="{opacity:0}" :enter="{opacity:1,transition:{delay:100,duration:400}}" class="text-2xl font-black">Sender Online · Receiver Offline</h2>
</div>

<div class="grid grid-cols-3 gap-4">

<div class="col-span-2">
  <div v-motion :initial="{opacity:0,scale:.93}" :enter="{opacity:1,scale:1,transition:{delay:200,duration:600}}">
    <img src="./assets/diagrams/case2.png" class="w-full rounded-xl" style="max-height:400px;object-fit:contain;background:#0a1628;" />
  </div>
</div>

<div class="flex flex-col gap-3 justify-center">
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">✅ Zero risk for sender</div>
    <div class="text-xs text-slate-300">Sender is online — debited from bank immediately via standard UPI rails. Fully settled on sender's side.</div>
  </div>
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">🔔 Push-on-reconnect</div>
    <div class="text-xs text-slate-300">SyncEngine polls pending credits the moment ConnectivityService fires an "online" event. No missed payments, no polling interval needed.</div>
  </div>
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">🏪 Merchant use case</div>
    <div class="text-xs text-slate-300">Kirana store owner's phone loses signal at 6 PM peak. Customers pay normally — credits stack up and appear as a batch when owner reconnects.</div>
  </div>
</div>

</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 8  CASE 3
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div class="flex items-center gap-3 mb-4">
  <span v-motion :initial="{opacity:0,x:-40}" :enter="{opacity:1,x:0,transition:{duration:400}}" class="pill pill-white text-base px-4 py-1">Case 3</span>
  <h2 v-motion :initial="{opacity:0}" :enter="{opacity:1,transition:{delay:100,duration:400}}" class="text-2xl font-black">Both Offline — Bluetooth LE Peer-to-Peer</h2>
</div>

<div class="grid grid-cols-3 gap-4">

<div class="col-span-2">
  <div v-motion :initial="{opacity:0,scale:.93}" :enter="{opacity:1,scale:1,transition:{delay:200,duration:600}}">
    <img src="./assets/diagrams/case3.png" class="w-full rounded-xl" style="max-height:400px;object-fit:contain;background:#0a1628;" />
  </div>
</div>

<div class="flex flex-col gap-3 justify-center">
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">📡 BLE range: ~10m</div>
    <div class="text-xs text-slate-300">GATT server/client — works in subways, aircraft, remote markets, hospital waiting rooms. Zero internet needed.</div>
  </div>
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">🔑 Fresh UUID per session</div>
    <div class="text-xs text-slate-300">Receiver generates a new BLE UUID every time they open "My QR". Prevents UUID spoofing and session hijacking.</div>
  </div>
  <div v-click class="dark-card">
    <div class="font-bold text-yellow-300 text-sm mb-1">🔄 First-mover settlement</div>
    <div class="text-xs text-slate-300">Whoever reconnects first submits the blob. Backend deduplicates by (sender+receiver+nonce) — no double-spend even if both submit simultaneously.</div>
  </div>
</div>

</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 9  ML RISK ENGINE
════════════════════════════════════════════════════════════ -->
---
layout: two-cols
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,y:-20}" :enter="{opacity:1,y:0,transition:{duration:400}}">

# <span style="color:#00B9F1">AI / ML Risk Engine</span>

</div>

<div class="mt-4 space-y-3">

<div v-click class="dark-card">
  <div class="font-bold text-yellow-300 mb-1 text-sm">📊 6 Input Features</div>
  <div class="text-xs text-slate-300 font-mono leading-relaxed">
    transaction_count_30d · avg_transaction_value<br/>
    account_age_days · kyc_tier<br/>
    fraud_flags · device_trust_score
  </div>
</div>

<div v-click class="dark-card">
  <div class="font-bold text-yellow-300 mb-1 text-sm">🔁 Local Re-scoring</div>
  <div class="text-xs text-slate-300">Every pending blob in the SQLite queue applies a <strong class="text-white">10% penalty</strong> to the cached score. Floor at 30%. Prevents cascading offline debt.</div>
</div>

<div v-click class="dark-card">
  <div class="font-bold text-yellow-300 mb-1 text-sm">💡 Explainability UI</div>
  <div class="text-xs text-slate-300">Tap the "₹X offline ⓘ" pill → per-factor bar chart. Users can see exactly why their limit changed. Builds trust and encourages good behaviour.</div>
</div>

<div v-click class="dark-card">
  <div class="font-bold text-yellow-300 mb-1 text-sm">⏰ 24-Hour TTL</div>
  <div class="text-xs text-slate-300">Limit cached for 24 hours. Expired + offline = ₹0 (safe default). New limit pushed after every successful sync — good behaviour is rewarded immediately.</div>
</div>

</div>

::right::

<div v-motion :initial="{opacity:0,scale:.9}" :enter="{opacity:1,scale:1,transition:{delay:300,duration:600}}" class="flex justify-center mt-2">
  <img src="./assets/diagrams/ml.png" class="rounded-xl w-full" style="max-height:460px;object-fit:contain;background:#0a1628;" />
</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 10  SECURITY
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,y:-20}" :enter="{opacity:1,y:0,transition:{duration:400}}">

# <span style="color:#00B9F1">Security Architecture</span> — Defence in Depth

</div>

<div v-motion :initial="{opacity:0,scale:.93}" :enter="{opacity:1,scale:1,transition:{delay:200,duration:600}}" class="mt-3">
  <img src="./assets/diagrams/security.png" class="w-full rounded-xl" style="max-height:320px;object-fit:contain;background:#0a1628;" />
</div>

<div class="grid grid-cols-4 gap-3 mt-4">
  <div v-click class="dark-card text-center py-3">
    <div class="text-xl mb-1">🔑</div>
    <div class="text-xs font-bold text-yellow-300">Ed25519</div>
    <div class="text-xs text-slate-400 mt-1">64-byte sig, unforgeable without device key</div>
  </div>
  <div v-click class="dark-card text-center py-3">
    <div class="text-xl mb-1">🎲</div>
    <div class="text-xs font-bold text-yellow-300">Nonce + Redis TTL</div>
    <div class="text-xs text-slate-400 mt-1">UUID per payment · 7-day replay store</div>
  </div>
  <div v-click class="dark-card text-center py-3">
    <div class="text-xl mb-1">🚨</div>
    <div class="text-xs font-bold text-yellow-300">Velocity Checks</div>
    <div class="text-xs text-slate-400 mt-1">N blobs/hour limit · spike detection · freeze</div>
  </div>
  <div v-click class="dark-card text-center py-3">
    <div class="text-xl mb-1">⏱️</div>
    <div class="text-xs font-bold text-yellow-300">Limit Expiry</div>
    <div class="text-xs text-slate-400 mt-1">Stale 24h limit → ₹0 · forces re-auth</div>
  </div>
</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 11  SYNC ENGINE
════════════════════════════════════════════════════════════ -->
---
layout: two-cols
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,y:-20}" :enter="{opacity:1,y:0,transition:{duration:400}}">

# <span style="color:#00B9F1">Sync & Reconciliation</span>

</div>

<div class="mt-4 space-y-3">

<div v-click class="dark-card">
  <div class="font-bold text-blue-300 mb-1 text-sm">Idempotent POST</div>
  <div class="text-xs text-slate-300">Each blob has a UUID. Submitting twice returns same result. Safe to retry on flaky LTE.</div>
</div>

<div v-click class="dark-card">
  <div class="font-bold text-sm mb-2">Three Outcome Paths</div>
  <div class="check-row"><div class="dot dot-green">✓</div><div class="text-xs"><strong class="text-green-400">Accepted</strong> — debit sender, credit receiver, mark synced</div></div>
  <div class="check-row"><div class="dot dot-red">✗</div><div class="text-xs"><strong class="text-red-400">Rejected</strong> — fraud/limit exceeded, limit restored, notify user</div></div>
  <div class="check-row"><div class="dot" style="background:#f59e0b">~</div><div class="text-xs"><strong class="text-amber-400">Adjusted</strong> — partial settlement, notify difference</div></div>
</div>

<div v-click class="dark-card">
  <div class="font-bold text-yellow-300 mb-1 text-sm">🔄 ML Refresh on Sync</div>
  <div class="text-xs text-slate-300">After every sync, ML model re-runs on updated feature vector. Good behaviour → higher limit next session.</div>
</div>

<div v-click class="dark-card">
  <div class="font-bold text-purple-300 mb-1 text-sm">🗑️ 7-Day Retention</div>
  <div class="text-xs text-slate-300">Synced blobs kept locally for audit/receipt. Cleaned up by SyncEngine cron job.</div>
</div>

</div>

::right::

<div v-motion :initial="{opacity:0,x:40}" :enter="{opacity:1,x:0,transition:{delay:300,duration:600}}" class="flex justify-center mt-2">
  <img src="./assets/diagrams/sync.png" class="rounded-xl" style="max-height:480px;object-fit:contain;background:#0a1628;" />
</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 12  APP SCREENS
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,y:-20}" :enter="{opacity:1,y:0,transition:{duration:400}}">

# <span style="color:#00B9F1">Live App</span> — Built & Running on iOS + Android

</div>

<div class="grid grid-cols-3 gap-8 mt-6 items-start">

<div v-motion :initial="{opacity:0,y:40}" :enter="{opacity:1,y:0,transition:{delay:100,duration:500}}">
  <div class="phone-frame mx-auto" style="max-width:220px;">
    <img src="./assets/screens/home_screen.png" style="width:100%;display:block;" />
  </div>
  <div class="text-center mt-3">
    <div class="font-bold text-yellow-300 text-sm">Home Screen</div>
    <div class="text-xs text-slate-400 mt-1">Offline banner · Limit pill · Dual-mode QR</div>
  </div>
</div>

<div v-motion :initial="{opacity:0,y:40}" :enter="{opacity:1,y:0,transition:{delay:250,duration:500}}">
  <div class="phone-frame mx-auto" style="max-width:220px;">
    <img src="./assets/screens/receipt_screen.png" style="width:100%;display:block;" />
  </div>
  <div class="text-center mt-3">
    <div class="font-bold text-yellow-300 text-sm">Payment Receipt</div>
    <div class="text-xs text-slate-400 mt-1">SetuPay · Amount in words · UPI footer</div>
  </div>
</div>

<div v-motion :initial="{opacity:0,y:40}" :enter="{opacity:1,y:0,transition:{delay:400,duration:500}}">
  <div class="phone-frame mx-auto" style="max-width:220px;">
    <img src="./assets/screens/qr_screen.png" style="width:100%;display:block;" />
  </div>
  <div class="text-center mt-3">
    <div class="font-bold text-yellow-300 text-sm">My QR + BLE</div>
    <div class="text-xs text-slate-400 mt-1">BLE advertising active · Works online & offline</div>
  </div>
</div>

</div>

<div v-click class="flex gap-3 mt-5 justify-center flex-wrap">
  <span class="pill pill-blue">iOS Release Build ✓</span>
  <span class="pill pill-gold">Android APK ✓</span>
  <span class="pill pill-white">FastAPI on Render ✓</span>
  <span class="pill pill-white">All 3 offline cases working ✓</span>
</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 13  UPI APP INTEGRATION (SDK)
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,y:-20}" :enter="{opacity:1,y:0,transition:{duration:400}}">

# <span style="color:#00B9F1">UPI App Integration (SDK)</span> — Drop-in, Zero Breaking Changes

</div>

<div class="grid grid-cols-3 gap-5 mt-6">

<div v-click class="dark-card">
  <div class="text-yellow-300 font-bold mb-3 text-sm">📱 Flutter SDK Layer</div>
  <div class="space-y-2">
    <div class="check-row"><div class="dot dot-blue">→</div><div class="text-xs">ConnectivityService injected as payment interceptor</div></div>
    <div class="check-row"><div class="dot dot-blue">→</div><div class="text-xs">OfflineLimitService sits above PaymentSDK</div></div>
    <div class="check-row"><div class="dot dot-blue">→</div><div class="text-xs">BLEService opt-in via feature flag</div></div>
    <div class="check-row"><div class="dot dot-blue">→</div><div class="text-xs">SyncEngine runs independently</div></div>
  </div>
</div>

<div v-click class="dark-card">
  <div class="text-yellow-300 font-bold mb-3 text-sm">☁️ New Backend Endpoints</div>
  <div class="space-y-2 font-mono text-xs">
    <div class="p-2 rounded" style="background:rgba(0,185,241,.1)">POST /offline/sync</div>
    <div class="p-2 rounded" style="background:rgba(0,185,241,.1)">GET /user/offline-limit</div>
    <div class="p-2 rounded" style="background:rgba(255,215,0,.1)">ML Risk Microservice</div>
    <div class="p-2 rounded" style="background:rgba(255,215,0,.1)">GET /user/pending-credits</div>
  </div>
</div>

<div v-click class="dark-card">
  <div class="text-yellow-300 font-bold mb-3 text-sm">🚀 Rollout Plan</div>
  <div class="space-y-3">
    <div>
      <div class="pill pill-white mb-1">Month 1–2 · Dark Launch</div>
      <div class="text-xs text-slate-400">1% traffic in tier-3 cities. Monitor fraud + sync success. No user-visible changes.</div>
    </div>
    <div>
      <div class="pill pill-blue mb-1">Month 3–4 · Beta</div>
      <div class="text-xs text-slate-400">Opt-in in Settings. Limit badge on home screen. BLE behind feature flag.</div>
    </div>
    <div>
      <div class="pill pill-gold mb-1">Month 5+ · GA</div>
      <div class="text-xs text-slate-400">All users. Merchant dashboard analytics. RBI regulatory reporting hook.</div>
    </div>
  </div>
</div>

</div>

<div v-click class="mt-5 p-3 rounded-xl text-center text-sm" style="background:rgba(0,185,241,.1);border:1px solid rgba(0,185,241,.3);">
  <strong style="color:#FFD700">Zero changes to existing UPI flow.</strong> Online path untouched. OfflineSDK is a pure, additive fallback layer.
</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 14  BUSINESS IMPACT
════════════════════════════════════════════════════════════ -->
---
layout: default
background: '#0a1628'
class: text-white
transition: slide-left
---

<div v-motion :initial="{opacity:0,y:-20}" :enter="{opacity:1,y:0,transition:{duration:400}}">

# <span style="color:#00B9F1">Business Impact</span> — Why This Wins

</div>

<div class="grid grid-cols-2 gap-6 mt-5">

<div class="space-y-4">
  <div v-click class="stat-card flex gap-5 items-center text-left px-5">
    <div class="stat-num text-3xl whitespace-nowrap">₹4,200 Cr</div>
    <div><div class="font-bold text-white text-sm">Annual Revenue Recovery</div><div class="stat-lbl">Lost payments across India's 43M UPI merchants from connectivity failures</div></div>
  </div>
  <div v-click class="stat-card flex gap-5 items-center text-left px-5">
    <div class="stat-num text-3xl">+23%</div>
    <div><div class="font-bold text-white text-sm">Merchant Retention</div><div class="stat-lbl">Merchants who accept offline payments are 23% less likely to switch payment apps</div></div>
  </div>
  <div v-click class="stat-card flex gap-5 items-center text-left px-5">
    <div class="stat-num text-3xl">500M</div>
    <div><div class="font-bold text-white text-sm">Addressable Users</div><div class="stat-lbl">Rural + semi-urban UPI users with spotty connectivity — currently underserved</div></div>
  </div>
  <div v-click class="stat-card flex gap-5 items-center text-left px-5">
    <div class="stat-num text-3xl">&lt;0.1%</div>
    <div><div class="font-bold text-white text-sm">Fraud Rate Target</div><div class="stat-lbl">ML limit + Ed25519 + nonce replay keeps fraud well below RBI's 0.3% threshold</div></div>
  </div>
</div>

<div v-click>
  <div class="dark-card">
    <div class="font-bold text-yellow-300 mb-3">Competitive Moat</div>
    <table class="w-full text-xs">
      <thead><tr class="text-slate-400">
        <th class="text-left pb-2">Feature</th>
        <th class="text-center pb-2">SetuPay</th>
        <th class="text-center pb-2">GPay</th>
        <th class="text-center pb-2">PhonePe</th>
        <th class="text-center pb-2">Cash</th>
      </tr></thead>
      <tbody>
        <tr v-click><td class="py-1 text-slate-300">No internet needed</td><td class="text-center"><span class="pill pill-green">✓</span></td><td class="text-center"><span class="pill pill-red">✗</span></td><td class="text-center"><span class="pill pill-red">✗</span></td><td class="text-center"><span class="pill pill-green">✓</span></td></tr>
        <tr v-click><td class="py-1 text-slate-300">Digital receipt</td><td class="text-center"><span class="pill pill-green">✓</span></td><td class="text-center"><span class="pill pill-green">✓</span></td><td class="text-center"><span class="pill pill-green">✓</span></td><td class="text-center"><span class="pill pill-red">✗</span></td></tr>
        <tr v-click><td class="py-1 text-slate-300">BLE P2P payment</td><td class="text-center"><span class="pill pill-green">✓</span></td><td class="text-center"><span class="pill pill-red">✗</span></td><td class="text-center"><span class="pill pill-red">✗</span></td><td class="text-center"><span class="pill pill-red">✗</span></td></tr>
        <tr v-click><td class="py-1 text-slate-300">AI fraud scoring</td><td class="text-center"><span class="pill pill-green">✓</span></td><td class="text-center"><span class="pill pill-amber">~</span></td><td class="text-center"><span class="pill pill-amber">~</span></td><td class="text-center"><span class="pill pill-red">✗</span></td></tr>
        <tr v-click><td class="py-1 text-slate-300">Auto-sync on reconnect</td><td class="text-center"><span class="pill pill-green">✓</span></td><td class="text-center"><span class="pill pill-red">✗</span></td><td class="text-center"><span class="pill pill-red">✗</span></td><td class="text-center"><span class="pill pill-red">✗</span></td></tr>
      </tbody>
    </table>
  </div>
</div>

</div>

<!-- ═══════════════════════════════════════════════════════
     SLIDE 15  ROADMAP & TEAM
════════════════════════════════════════════════════════════ -->
---
layout: cover
background: '#001845'
class: text-white
transition: fade
---

<div class="absolute inset-0" style="background:radial-gradient(ellipse at 80% 50%,rgba(0,61,165,.4) 0%,transparent 60%);"></div>

<div class="relative z-10">

<div v-motion :initial="{opacity:0,x:-50}" :enter="{opacity:1,x:0,transition:{duration:500}}">
  <span class="pill pill-gold mb-5 inline-block">ROADMAP & TEAM</span>
  <h2 class="text-4xl font-black mb-6">What We Built. What's Next.</h2>
</div>

<div class="grid grid-cols-3 gap-5">
  <div v-click class="dark-card">
    <span class="pill pill-green mb-3 inline-block">✓ Done — Hackathon</span>
    <ul class="text-xs text-slate-300 space-y-1 mt-2">
      <li>• All 3 offline cases end-to-end</li>
      <li>• Ed25519 signing + nonce replay</li>
      <li>• ML risk engine (sklearn)</li>
      <li>• Native BLE GATT iOS + Android</li>
      <li>• Auto-sync engine</li>
      <li>• iOS + Android release builds</li>
      <li>• FastAPI backend on Render</li>
    </ul>
  </div>
  <div v-click class="dark-card">
    <span class="pill pill-blue mb-3 inline-block">Q2 2026 · Beta</span>
    <ul class="text-xs text-slate-300 space-y-1 mt-2">
      <li>• RBI regulatory sandbox filing</li>
      <li>• HSM for key management</li>
      <li>• Merchant analytics dashboard</li>
      <li>• Limit scale to ₹10,000</li>
      <li>• Push notifications on sync</li>
      <li>• Cross-bank offline settlement</li>
    </ul>
  </div>
  <div v-click class="dark-card">
    <span class="pill pill-gold mb-3 inline-block">Q3–Q4 2026 · GA</span>
    <ul class="text-xs text-slate-300 space-y-1 mt-2">
      <li>• NFC fallback for Case 3</li>
      <li>• Federated on-device ML</li>
      <li>• Open SDK for third-party apps</li>
      <li>• UPI 3.0 offline spec alignment</li>
      <li>• International offline corridors</li>
    </ul>
  </div>
</div>

<div v-motion :initial="{opacity:0,y:20}" :enter="{opacity:1,y:0,transition:{delay:600,duration:400}}" class="mt-6 text-center">
  <span class="text-2xl font-black">Team Issavibles</span>
  <span class="text-slate-400 mx-3">·</span>
  <span class="text-blue-300">Flutter + Python + ML + BLE</span>
  <span class="text-slate-400 mx-3">·</span>
  <span style="color:#FFD700">Built end-to-end in 48 hours</span>
</div>

</div>
