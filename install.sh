#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_APP="$ROOT_DIR/.build/app/Codex Voice.app"
TARGET_APP="/Applications/Codex Voice.app"
BUNDLE_ID="dev.starkpat.codexvoice"
TEMP_ROOT=""

cleanup() {
  case "$TEMP_ROOT" in
    /Applications/.codexvoice-install.*)
      test ! -e "$TEMP_ROOT" || /bin/rm -rf -- "$TEMP_ROOT"
      ;;
  esac
}
trap cleanup EXIT

bundle_id() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

validate_owned_bundle() {
  local app="$1"
  test -d "$app" -a ! -L "$app"
  test -f "$app/Contents/Info.plist" -a ! -L "$app/Contents/Info.plist"
  test "$(bundle_id "$app")" = "$BUNDLE_ID"
}

CODEX_VOICE_REQUIRE_DEVELOPER_ID=1 "$ROOT_DIR/Scripts/build-app.sh" >/dev/null
validate_owned_bundle "$SOURCE_APP"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"

/usr/bin/pkill -x CodexVoice >/dev/null 2>&1 || true
for _ in {1..20}; do
  /usr/bin/pgrep -x CodexVoice >/dev/null 2>&1 || break
  /bin/sleep 0.1
done
if /usr/bin/pgrep -x CodexVoice >/dev/null 2>&1; then
  echo "Codex Voice did not stop cleanly" >&2
  exit 1
fi

if test -e "$TARGET_APP"; then
  validate_owned_bundle "$TARGET_APP" || {
    echo "refusing to replace an unrecognized app at $TARGET_APP" >&2
    exit 1
  }
  timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
  backup="$HOME/.Trash/Codex Voice-$timestamp.app"
  /bin/mv "$TARGET_APP" "$backup"
  echo "Previous app moved to $backup"
fi

TEMP_ROOT="$(/usr/bin/mktemp -d '/Applications/.codexvoice-install.XXXXXX')"
/usr/bin/ditto "$SOURCE_APP" "$TEMP_ROOT/Codex Voice.app"
validate_owned_bundle "$TEMP_ROOT/Codex Voice.app"
/usr/bin/codesign --verify --deep --strict "$TEMP_ROOT/Codex Voice.app"
/bin/mv "$TEMP_ROOT/Codex Voice.app" "$TARGET_APP"
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"
/usr/bin/open -n "$TARGET_APP"

for _ in {1..30}; do
  /usr/bin/pgrep -x CodexVoice >/dev/null 2>&1 && break
  /bin/sleep 0.1
done
/usr/bin/pgrep -x CodexVoice >/dev/null
echo "Installed and launched $TARGET_APP"
