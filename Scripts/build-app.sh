#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="Codex Voice"
EXECUTABLE_NAME="CodexVoice"
BUNDLE_ID="dev.starkpat.codexvoice"
OUTPUT_ROOT="$ROOT_DIR/.build/app"
APP_BUNDLE="$OUTPUT_ROOT/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"

case "$APP_BUNDLE" in
  "$ROOT_DIR"/.build/app/*) ;;
  *) echo "unsafe app output path: $APP_BUNDLE" >&2; exit 1 ;;
esac

cd "$ROOT_DIR"
swift build -c release --product "$EXECUTABLE_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"
BUILD_BINARY="$BIN_DIR/$EXECUTABLE_NAME"
test -f "$BUILD_BINARY" -a -x "$BUILD_BINARY"

/bin/rm -rf -- "$APP_BUNDLE"
/bin/mkdir -p "$MACOS_DIR"
/bin/cp "$BUILD_BINARY" "$MACOS_DIR/$EXECUTABLE_NAME"
/bin/chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"
/bin/cp "$ROOT_DIR/Config/CodexVoice-Info.plist" "$CONTENTS/Info.plist"

/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null
actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS/Info.plist")"
test "$actual_id" = "$BUNDLE_ID"

/usr/bin/codesign --force --sign - \
  --entitlements "$ROOT_DIR/Config/CodexVoice.entitlements" \
  "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

printf '%s\n' "$APP_BUNDLE"
