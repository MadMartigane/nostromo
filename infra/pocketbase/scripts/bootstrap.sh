#!/usr/bin/env bash
# Local DEV bootstrap for Nostromo (plan task T6). DEV ONLY, never for production.
#
# Idempotent: creates/updates the local superuser, waits for a running instance, then
# creates the first application user through the superuser-only invite endpoint.
# Running it twice changes nothing.
#
# This script does NOT start the server. The documented sequence is:
#   bash infra/pocketbase/scripts/serve.sh &      # or in another terminal
#   bash infra/pocketbase/scripts/bootstrap.sh
#
# Credentials below are development-only and never production-looking. Both this script and
# smoke.sh default to the same dev credentials, so smoke.sh runs with no environment
# overrides: dev@nostromo.local / DevOnly1!. The password is at least 8 characters because
# PocketBase rejects shorter superuser passwords (the _superusers collection enforces
# "Must be at least 8 character(s)"). Change both scripts together if you change it.
set -euo pipefail

# --- configuration (dev defaults, overridable through the environment) ------------------

readonly HTTP_ADDR="127.0.0.1:8090"
BASE_URL="${BASE_URL:-http://${HTTP_ADDR}}"
SUPERUSER_EMAIL="${SUPERUSER_EMAIL:-dev@nostromo.local}"
SUPERUSER_PASSWORD="${SUPERUSER_PASSWORD:-DevOnly1!}"

# PocketBase rejects shorter superuser passwords; fail fast with a readable message
# instead of surfacing the raw CLI validation error.
readonly MIN_PASSWORD_LENGTH=8

readonly FIRST_USER_EMAIL="app@nostromo.local"
readonly FIRST_USER_NAME="Local Dev App User"

readonly HEALTH_TIMEOUT_SECONDS=15
readonly HEALTH_RETRY_INTERVAL_SECONDS=1

# --- paths (resolved from the script location, so any cwd works) ------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PB_BIN="$ROOT_DIR/pocketbase"
PB_DATA="$ROOT_DIR/pb_data"

# --- helpers ---------------------------------------------------------------------------

# api_json METHOD PATH TOKEN OUT_FILE [JSON_BODY]
# Prints the HTTP status on stdout and stores the response body in OUT_FILE.
# Never uses curl -f: non-2xx statuses are part of the contract and checked by the caller.
api_json() {
  local method="$1" path="$2" token="$3" out="$4" body="${5:-}"
  local args=(-sS -X "$method" -o "$out" -w '%{http_code}')
  if [[ -n "$token" ]]; then
    args+=(-H "Authorization: $token")
  fi
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  curl "${args[@]}" "$BASE_URL$path" || true
}

# json_get FILE KEY: prints a top-level string value, or an empty string when missing.
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    value = None
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

# json_body KEY VALUE [KEY VALUE ...]: prints a JSON object with safely escaped values.
json_body() {
  python3 -c '
import json, sys
pairs = sys.argv[1:]
print(json.dumps({pairs[i]: pairs[i + 1] for i in range(0, len(pairs), 2)}))
' "$@"
}

fail() {
  printf 'bootstrap: %s\n' "$1" >&2
  exit 1
}

if (( ${#SUPERUSER_PASSWORD} < MIN_PASSWORD_LENGTH )); then
  fail "SUPERUSER_PASSWORD must be at least ${MIN_PASSWORD_LENGTH} characters (PocketBase rejects shorter superuser passwords)."
fi

# --- 1. binary --------------------------------------------------------------------------

if [[ ! -x "$PB_BIN" ]]; then
  echo "PocketBase binary missing, downloading it first."
  "$SCRIPT_DIR/download.sh"
fi

# --- 2. superuser upsert (idempotent) ---------------------------------------------------

echo "Ensuring dev superuser ${SUPERUSER_EMAIL} exists (DEV ONLY credentials)."
"$PB_BIN" superuser upsert "$SUPERUSER_EMAIL" "$SUPERUSER_PASSWORD" --dir "$PB_DATA" >/dev/null

# --- 3. wait for the local instance -----------------------------------------------------

health_ok=0
for _ in $(seq 1 "$HEALTH_TIMEOUT_SECONDS"); do
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/api/health" || true)" == "200" ]]; then
    health_ok=1
    break
  fi
  sleep "$HEALTH_RETRY_INTERVAL_SECONDS"
done

if [[ "$health_ok" != "1" ]]; then
  fail "no PocketBase instance answering ${BASE_URL}/api/health after ${HEALTH_TIMEOUT_SECONDS}s.
Start it first in another terminal: bash infra/pocketbase/scripts/serve.sh"
fi

# --- 4. authenticate as the superuser ---------------------------------------------------

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

auth_status="$(api_json POST /api/collections/_superusers/auth-with-password "" "$TMP_DIR/auth.json" \
  "$(json_body identity "$SUPERUSER_EMAIL" password "$SUPERUSER_PASSWORD")")"
SUPERUSER_TOKEN="$(json_get "$TMP_DIR/auth.json" token)"

if [[ "$auth_status" != "200" || -z "$SUPERUSER_TOKEN" ]]; then
  fail "superuser authentication failed (status ${auth_status}). Check SUPERUSER_EMAIL/SUPERUSER_PASSWORD."
fi

# --- 5. idempotent first application user (via the superuser-only invite route) ---------

invite_status="$(api_json POST /nostromo/invite "$SUPERUSER_TOKEN" "$TMP_DIR/invite.json" \
  "$(json_body email "$FIRST_USER_EMAIL" name "$FIRST_USER_NAME")")"
FIRST_USER_ID="$(json_get "$TMP_DIR/invite.json" userId)"
invite_created="$(json_get "$TMP_DIR/invite.json" created)"

if [[ "$invite_status" != "200" || -z "$FIRST_USER_ID" ]]; then
  fail "invite of ${FIRST_USER_EMAIL} failed (status ${invite_status}, body: $(tr '\n' ' ' < "$TMP_DIR/invite.json"))"
fi

if [[ "$invite_created" == "true" ]]; then
  echo "Created first application user ${FIRST_USER_EMAIL} (id ${FIRST_USER_ID})."
  echo "  generated password (shown once, DEV ONLY): $(json_get "$TMP_DIR/invite.json" password)"
else
  echo "First application user ${FIRST_USER_EMAIL} already exists (id ${FIRST_USER_ID}), nothing changed."
fi

# --- 6. summary and warning -------------------------------------------------------------

cat <<EOF

Nostromo local development bootstrap complete.

  Admin UI:      http://${HTTP_ADDR}/_
  API:           http://${HTTP_ADDR}/api/
  Superuser:     ${SUPERUSER_EMAIL} / ${SUPERUSER_PASSWORD}
  First user:    ${FIRST_USER_EMAIL}

WARNING: these credentials are DEVELOPMENT-ONLY. They are not secret, must never
be reused, and must never reach a shared or production environment.
EOF
