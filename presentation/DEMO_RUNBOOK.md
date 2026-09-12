# SetuPay — Demo Day Runbook

**Event:** Build in AI for India · Sept 13, 2026
**Branch:** `demo-day` · **Backup:** recorded video on the laptop desktop

The one rule: **after 5 PM, fix nothing new.** Rehearse, don't build.

---

## 1. Phone prep checklist

Run this **the night before AND 30 minutes before the demo**, on *both* phones.

### Both phones
- [ ] Latest `demo-day` APK installed
      (`adb install -r mobile/SetuPay-demo-day.apk`)
      Built with the laptop's LAN address baked in:
      `flutter build apk --release --target-platform android-arm64 \
         --dart-define=API_URL=http://<laptop-ip>:8000`
      **Rebuild if the venue gives the laptop a different IP.**
- [ ] Logged in — **Phone A = `vivek@demo.com`**, **Phone B = `ramesh@demo.com`**,
      both `password123`
- [ ] Device key registered: make one online test payment and confirm the ops
      dashboard shows `settled` with `signature_verified=true`
- [ ] Battery > 80 %, **brightness at max** (the QR handoff needs it)
- [ ] **Do Not Disturb ON** — a WhatsApp banner mid-demo on the projector is fatal
- [ ] Auto-rotate OFF
- [ ] **Bluetooth ON *after* enabling airplane mode.** Most phones kill BT when
      airplane mode goes on; re-enable it by hand every single time.

### Phone A (sender) only
- [ ] **Hindi on-device speech pack downloaded.** This is the #1 way voice
      silently dies on stage.
      On this OnePlus the recogniser is Google TTS/Speech Services:
      **Settings → Google → All services → Search, Assistant & Voice → Voice →
      Offline speech recognition → download हिन्दी (भारत)**.
      (On a Pixel it lives under Settings → System → Languages & input →
      On-device speech recognition.)
      *Verified on the demo phone:* the recogniser IS reachable from the app
      (package-visibility entry is in the manifest) — only the language pack
      is a manual step.
- [ ] **With hi_IN, Google returns Devanagari, not romanised Hinglish.** The
      parser handles both; nothing to do, but don't be alarmed if the live
      transcript reads "रमेश को दो सौ रुपये भेजो".
- [ ] Tap the mic once in the app and say anything — confirm a partial
      transcript appears. Do this **in the venue**, not just at home.
- [ ] Mic + camera permissions already granted (so no permission dialog appears
      on stage)

### Laptop
- [ ] Backend awake: `cd backend && ./run_local.sh --bg`, then hit
      `http://<laptop-ip>:8000/docs`.
      *On Render free tier, wake it 15 minutes early — cold start is ~50 s.*
- [ ] `SIGNATURE_ENFORCEMENT=enforce` in `backend/.env`
      — **flip this only after both phones show `signature_verified=true`**
- [ ] Dashboard fullscreen and bookmarked:
      `http://127.0.0.1:8000/dashboard/live?token=setupay-demo`
- [ ] Terminal ready with the attack command **pre-typed, not yet run**:
      `cd backend && .venv/bin/python -m demo.attack all`
- [ ] `scrcpy` mirroring Phone A, tested on the projector
- [ ] Both phones and the laptop on the **same LAN** — the app is built with
      `--dart-define=API_URL=http://<laptop-ip>:8000`
- [ ] Reset the feed so the stage starts clean:
      `curl -X POST "http://127.0.0.1:8000/api/ops/reset?token=setupay-demo"`
      then reseed a little activity if you want the panel populated.

---

## 2. The 3-minute script

> The dashboard is **already on screen** before you start talking.

**0:00 — Problem.**
"500 million Indians have UPI. It stops working the moment the network does."
Dashboard is live behind you with seeded activity.

**0:20 — Airplane mode ON, on camera.**
Hold the phone up. "UPI is now dead on this phone." *(Re-enable Bluetooth.)*

**0:30 — Voice payment, fully offline.**
Tap the mic. Say clearly: **"Ramesh ko do sau rupaye bhejo."**
Confirm screen reads **₹200 → Ramesh**. Tap Confirm.
Point at two things: the offline limit **dropping**, and the
**"Why this limit?"** card explaining it in Hinglish.
> If the mic misfires: tap **Re-record** once. If it fails twice, tap **Edit** —
> the transcript pre-fills the normal pay screen. Keep talking, don't apologise.

**1:10 — Handoff to the receiver's phone, still offline.**
Try **BLE first — 20-second budget.**
> If it stalls, say **"or simply—"** and tap **Hand off via QR**. Phone B scans.
> This is not a fallback you apologise for; it's the de-risked path. Receiver
> shows **₹200 received · pending settlement**, both phones still in airplane mode.

**1:45 — Wi-Fi back ON.**
Watch the dashboard: `blob_received` → `SETTLED`, the counter ticks, Vivek's
limit bar animates as the AI recalculates, and the explainer card updates.

**2:10 — "Now the fun part. Attack us."**
Run `python -m demo.attack all` on the laptop.
Four red cards appear with plain-language reasons — replay, forged signature,
over-limit, burst. Then the control payment settles right after, proving the
system isn't just refusing everything.

**2:45 — Close.**
"The AI trust layer is what makes offline money safe: a credit limit that
adapts, signatures that prove who paid, and explanations anyone can read."
One roadmap line: SMS rail → feature phones → UPI SDK.

---

## 3. If something breaks

| Symptom | Do this |
|---|---|
| Mic produces nothing | Re-record once, then **Edit** → typed amount. Never stand in silence. |
| BLE won't pair | **"or simply—"** → QR handoff. Budget 20 s, no more. |
| Dashboard shows "connection lost" | It self-heals in 2 s. Keep talking; don't reload the page mid-sentence. |
| Phone can't reach the backend | Check both are on the same LAN. Fallback: `adb reverse tcp:8000 tcp:8000`. |
| A payment is rejected unexpectedly | Read the reason off the dashboard aloud — the explainer text is human, so it looks intentional. |
| Backend wedged | `cd backend && ./restart_local.sh` (add `--reseed` to reset the cast). |
| Everything is on fire | Play the backup video. |

---

## 4. Reset between rehearsals

```bash
cd backend
./restart_local.sh --reseed                                     # fresh cast + clean DB
curl -X POST "http://127.0.0.1:8000/api/ops/reset?token=setupay-demo"
```
On the phones: clear app storage, or just log out and back in.

---

## 5. Demo cast

| Account | Password | Role | AI limit | Why |
|---|---|---|---|---|
| `vivek@demo.com` | `password123` | sender | ₹5,000 | KYC 3, 214 payments, 0 flags |
| `ramesh@demo.com` | `password123` | merchant receiver | — | the kirana store |
| `attacker@demo.com` | `password123` | attacker | ₹100 | KYC 0, 1-day-old account, 1 fraud flag |

The gap between Vivek's bar and the attacker's bar on the Trust Engine panel
*is* the AI story. Point at it.
