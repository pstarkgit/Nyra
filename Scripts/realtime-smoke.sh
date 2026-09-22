#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CODEX_BINARY="/Applications/ChatGPT.app/Contents/Resources/codex"

test -x "$CODEX_BINARY"
/usr/bin/python3 "$ROOT_DIR/Scripts/realtime-smoke.py" "$CODEX_BINARY" "$ROOT_DIR"
