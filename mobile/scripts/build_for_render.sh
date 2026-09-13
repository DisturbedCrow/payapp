#!/usr/bin/env bash
# Point the app at a Render deployment and build a universal APK.
#   ./scripts/build_for_render.sh https://your-service.onrender.com
set -euo pipefail
URL="${1:?usage: build_for_render.sh https://<service>.onrender.com}"
URL="${URL%/}"
cd "$(dirname "$0")/.."
source /home/vivek/Desktop/payapp/env.sh

echo "== checking $URL (free tier may need ~60s to wake) =="
for i in 1 2 3 4; do
  code=$(curl -s -o /tmp/rh.json -w "%{http_code}" -m 70 "$URL/health" || true)
  [ "$code" = "200" ] && { echo "  healthy: $(cat /tmp/rh.json)"; break; }
  echo "  attempt $i: HTTP $code"
  [ "$i" = "4" ] && { echo "Render is not answering /health — fix the deploy first."; exit 1; }
done

cfg=$(curl -s -m 30 "$URL/api/ops/config?token=${OPS_DASH_TOKEN:-setupay-demo}" || true)
echo "  ops config: ${cfg:-<token mismatch or old code>}"

echo "== building universal APK against $URL =="
flutter build apk --release \
  --target-platform android-arm,android-arm64,android-x64 \
  --android-skip-build-dependency-validation \
  --dart-define=PUBLIC_API_URL="$URL"
cp build/app/outputs/flutter-apk/app-release.apk SetuPay-demo-day.apk
cp SetuPay-demo-day.apk ~/Desktop/SetuPay-demo-day.apk
echo "== done: ~/Desktop/SetuPay-demo-day.apk ($(du -h SetuPay-demo-day.apk | cut -f1)) =="
