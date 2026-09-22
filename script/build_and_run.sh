#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Nyra"
PROCESS_NAME="Nyra"
BUNDLE_ID="dev.starkpat.nyra"
MIN_SYSTEM_VERSION="26.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
XCODE_ROOT="/Applications/Xcode.app/Contents/Developer"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if test -d "$XCODE_ROOT"; then
  export DEVELOPER_DIR="$XCODE_ROOT"
fi
SWIFT=(/usr/bin/xcrun swift)

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
"${SWIFT[@]}" build
BUILD_BINARY="$("${SWIFT[@]}" build --show-bin-path)/$PROCESS_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

/bin/cp "$ROOT_DIR/Config/CodexVoice-Info.plist" "$INFO_PLIST"
/bin/cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"

/usr/bin/codesign --force --sign - \
  --entitlements "$ROOT_DIR/Config/CodexVoice.entitlements" \
  "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }

case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$PROCESS_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
