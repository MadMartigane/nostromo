#!/usr/bin/env bash
# Download the pinned PocketBase binary into infra/pocketbase/.
#
# The binary is gitignored and must never be committed. Running this script
# twice in a row is a no-op when the binary already reports the pinned version.
set -euo pipefail

readonly VERSION="0.40.4"
readonly REPO_URL="https://github.com/pocketbase/pocketbase/releases/download"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PB_BIN="$ROOT_DIR/pocketbase"

has_pinned_version() {
  [ -x "$PB_BIN" ] && "$PB_BIN" --version 2>/dev/null | grep -q "$VERSION"
}

detect_os() {
  case "$(uname -s)" in
    Linux) echo "linux" ;;
    Darwin) echo "darwin" ;;
    *)
      echo "Unsupported OS: $(uname -s). Only linux and darwin are supported." >&2
      exit 1
      ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *)
      echo "Unsupported architecture: $(uname -m). Only amd64 and arm64 are supported." >&2
      exit 1
      ;;
  esac
}

if has_pinned_version; then
  echo "PocketBase ${VERSION} already present at ${PB_BIN} (no download needed)."
  exit 0
fi

OS="$(detect_os)"
ARCH="$(detect_arch)"
URL="${REPO_URL}/v${VERSION}/pocketbase_${VERSION}_${OS}_${ARCH}.zip"

echo "Downloading PocketBase ${VERSION} (${OS}/${ARCH})..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL "$URL" -o "$TMP_DIR/pocketbase.zip"
unzip -oq "$TMP_DIR/pocketbase.zip" -d "$TMP_DIR"
chmod +x "$TMP_DIR/pocketbase"
mv "$TMP_DIR/pocketbase" "$PB_BIN"

echo "Installed: $("$PB_BIN" --version)"
