#!/usr/bin/env bash
# Start PocketBase for local Nostromo development (127.0.0.1:8090).
#
# Downloads the pinned binary first if it is missing, then serves with the
# Nostromo data, migrations and hooks directories (absolute paths so the script
# works from any cwd). Dev-only CORS origins for a local frontend on port 3000.
set -euo pipefail

readonly HTTP_ADDR="127.0.0.1:8090"
readonly DEV_ORIGINS=("http://localhost:3000" "http://127.0.0.1:3000")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PB_BIN="$ROOT_DIR/pocketbase"

"$SCRIPT_DIR/download.sh"

mkdir -p "$ROOT_DIR/pb_data"

ORIGIN_FLAGS=()
for origin in "${DEV_ORIGINS[@]}"; do
  ORIGIN_FLAGS+=(--origins "$origin")
done

echo "Serving PocketBase on http://${HTTP_ADDR} (data: ${ROOT_DIR}/pb_data)"
exec "$PB_BIN" serve \
  --http "$HTTP_ADDR" \
  --dir "$ROOT_DIR/pb_data" \
  --migrationsDir "$ROOT_DIR/pb_migrations" \
  --hooksDir "$ROOT_DIR/pb_hooks" \
  --automigrate=0 \
  "${ORIGIN_FLAGS[@]}"
