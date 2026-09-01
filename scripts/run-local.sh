#!/usr/bin/env bash
#
# Run Halved on a physical device against the LOCAL Django server.
#
# Exists because the failure it prevents is invisible: forget
# `--dart-define=API_BASE=...` and the app silently talks to Railway while
# looking completely normal. That has burned an evening of debugging and a real
# Twilio SMS. The LAN IP is discovered rather than typed, so it cannot go stale
# when the network changes either.
#
#   ./scripts/run-local.sh                 # only device connected
#   ./scripts/run-local.sh <device-udid>   # pick one
#
# Pair with:  poetry run python manage.py runserver 0.0.0.0:8000
# (0.0.0.0, not the default — a phone cannot reach 127.0.0.1.)
set -euo pipefail

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ -z "$IP" ]; then
  echo "Could not find a LAN IP on en0/en1. Are you on Wi-Fi?" >&2
  exit 1
fi

API="http://$IP:8000/api"

# Fail early and loudly if the server is not reachable at that address — an
# unreachable base looks exactly like a broken app once it is on the phone.
if ! curl -sf -o /dev/null --max-time 5 "http://$IP:8000/admin/login/"; then
  echo "No server answering at http://$IP:8000/" >&2
  echo "Start it with: poetry run python manage.py runserver 0.0.0.0:8000" >&2
  exit 1
fi

cd "$(dirname "$0")/../mobile"

echo "→ API_BASE=$API"
echo "→ the app should show a GREEN '$IP' ribbon at bottom-left."
echo "  No ribbon means it is talking to PRODUCTION — stop and do not sign in."
echo

if [ $# -ge 1 ]; then
  exec flutter run --release -d "$1" --dart-define=API_BASE="$API"
fi
exec flutter run --release --dart-define=API_BASE="$API"
