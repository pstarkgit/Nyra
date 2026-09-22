#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
XCODE_ROOT="/Applications/Xcode.app/Contents/Developer"
APP_NAME="Nyra"
EXECUTABLE_NAME="Nyra"
BUNDLE_ID="dev.starkpat.nyra"
DEVELOPER_ID="Developer ID Application: Patrick Stark (P2M5LH6CVA)"
OUTPUT_ROOT="$ROOT_DIR/.build/app"
APP_BUNDLE="$OUTPUT_ROOT/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

if test -d "$XCODE_ROOT"; then
  export DEVELOPER_DIR="$XCODE_ROOT"
fi
SWIFT=(/usr/bin/xcrun swift)

case "$APP_BUNDLE" in
  "$ROOT_DIR"/.build/app/*) ;;
  *) echo "unsafe app output path: $APP_BUNDLE" >&2; exit 1 ;;
esac

cd "$ROOT_DIR"
"${SWIFT[@]}" build -c release --product "$EXECUTABLE_NAME"
BIN_DIR="$("${SWIFT[@]}" build -c release --show-bin-path)"
BUILD_BINARY="$BIN_DIR/$EXECUTABLE_NAME"
test -f "$BUILD_BINARY" -a -x "$BUILD_BINARY"

/bin/rm -rf -- "$APP_BUNDLE"
/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
/bin/cp "$BUILD_BINARY" "$MACOS_DIR/$EXECUTABLE_NAME"
/bin/chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"
/bin/cp "$ROOT_DIR/Config/CodexVoice-Info.plist" "$CONTENTS/Info.plist"
/bin/cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null
actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS/Info.plist")"
test "$actual_id" = "$BUNDLE_ID"

SIGN_IDENTITY="${NYRA_SIGN_IDENTITY:-}"
if test -z "$SIGN_IDENTITY"; then
  SIGN_IDENTITY="$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/grep -F "\"$DEVELOPER_ID\"" \
      | /usr/bin/head -n 1 \
      | /usr/bin/awk '{print $2}' \
      || true
  )"
fi
if test -z "$SIGN_IDENTITY" \
    && test "${NYRA_REQUIRE_DEVELOPER_ID:-0}" = "1"; then
  echo "required signing identity is unavailable: $DEVELOPER_ID" >&2
  exit 1
fi
test -n "$SIGN_IDENTITY" || SIGN_IDENTITY="-"

if test "$SIGN_IDENTITY" = "-"; then
  /usr/bin/codesign --force --sign - \
    --entitlements "$ROOT_DIR/Config/CodexVoice.entitlements" \
    "$APP_BUNDLE" >/dev/null
else
  /usr/bin/codesign --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$ROOT_DIR/Config/CodexVoice.entitlements" \
    "$APP_BUNDLE" >/dev/null
fi
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

printf '%s\n' "$APP_BUNDLE"
