#!/usr/bin/env bash
# Start the SetuPay backend locally with demo-day settings.
#   ./run_local.sh            foreground
#   ./run_local.sh --bg       background, logs to /tmp/setupay-backend.log
set -euo pipefail
cd "$(dirname "$0")"
if [ -f .env ]; then set -a; . ./.env; set +a; fi
export DEMO_MODE="${DEMO_MODE:-true}"
export SIGNATURE_ENFORCEMENT="${SIGNATURE_ENFORCEMENT:-enforce}"
export OPS_DASH_TOKEN="${OPS_DASH_TOKEN:-setupay-demo}"
export EXPLAINER_PROVIDER="${EXPLAINER_PROVIDER:-mock}"
if [ "${1:-}" = "--bg" ]; then
  nohup .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 \
    > /tmp/setupay-backend.log 2>&1 &
  echo "backend pid $! → /tmp/setupay-backend.log"
else
  exec .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
fi
