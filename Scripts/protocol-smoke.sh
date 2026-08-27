#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CODEX_BINARY="/Applications/ChatGPT.app/Contents/Resources/codex"
SCHEMA_DIR="$(/usr/bin/mktemp -d /tmp/codexvoice-schema.XXXXXX)"

cleanup() {
  case "$SCHEMA_DIR" in
    /tmp/codexvoice-schema.*) /bin/rm -rf -- "$SCHEMA_DIR" ;;
  esac
}
trap cleanup EXIT

test -x "$CODEX_BINARY"
"$CODEX_BINARY" app-server generate-json-schema --experimental --out "$SCHEMA_DIR" >/dev/null
for method in thread/start turn/start item/agentMessage/delta turn/completed; do
  rg -q "\"$method\"" "$SCHEMA_DIR/codex_app_server_protocol.schemas.json"
done

/usr/bin/python3 "$ROOT_DIR/Scripts/protocol_smoke.py" "$CODEX_BINARY" "$ROOT_DIR"
