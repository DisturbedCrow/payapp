#!/usr/bin/env bash
# Stop any running local backend, optionally reseed, and start a fresh one.
#   ./restart_local.sh           restart, keep the database
#   ./restart_local.sh --reseed  wipe offline_pay.db and reseed first
set -uo pipefail
cd "$(dirname "$0")"

PATTERN='uvicorn app[.]main:app'

# Only ever kill real Python processes. pgrep -f also matches any shell whose
# command line merely mentions the pattern — including the one invoking this
# script — and killing that takes the caller down with it.
kill_backends() {
  local sig="$1" pid comm
  for pid in $(pgrep -f "$PATTERN" 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "")
    case "$comm" in python*|uvicorn*) kill "-$sig" "$pid" 2>/dev/null ;; esac
  done
}

running() {
  local pid comm
  for pid in $(pgrep -f "$PATTERN" 2>/dev/null); do
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "")
    case "$comm" in python*|uvicorn*) return 0 ;; esac
  done
  return 1
}

kill_backends TERM
for _ in $(seq 20); do running || break; sleep 0.25; done
running && kill_backends KILL

if [ "${1:-}" = "--reseed" ]; then
  rm -f offline_pay.db demo/.sent_blobs.json
  .venv/bin/python seed.py >/dev/null 2>&1
  echo "database reseeded"
fi

setsid ./run_local.sh --bg < /dev/null > /dev/null 2>&1
for _ in $(seq 40); do
  sleep 0.5
  if curl -sf http://127.0.0.1:8000/health >/dev/null 2>&1; then echo "backend up"; exit 0; fi
done
echo "backend FAILED to start; tail of log:"; tail -20 /tmp/setupay-backend.log; exit 1
