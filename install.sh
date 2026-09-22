#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_APP="$ROOT_DIR/.build/app/Nyra.app"
TARGET_APP="/Applications/Nyra.app"
BUNDLE_ID="dev.starkpat.nyra"
TEMP_ROOT=""

cleanup() {
  case "$TEMP_ROOT" in
    /Applications/.nyra-install.*)
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

NYRA_REQUIRE_DEVELOPER_ID=1 "$ROOT_DIR/Scripts/build-app.sh" >/dev/null
validate_owned_bundle "$SOURCE_APP"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP"

/usr/bin/pkill -x Nyra >/dev/null 2>&1 || true
for _ in {1..20}; do
  /usr/bin/pgrep -x Nyra >/dev/null 2>&1 || break
  /bin/sleep 0.1
done
if /usr/bin/pgrep -x Nyra >/dev/null 2>&1; then
  echo "Nyra did not stop cleanly" >&2
  exit 1
fi

if test -e "$TARGET_APP"; then
  validate_owned_bundle "$TARGET_APP" || {
    echo "refusing to replace an unrecognized app at $TARGET_APP" >&2
    exit 1
  }
  timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
  user_name="$(/usr/bin/id -un)"
  user_home="$(/usr/bin/dscl . -read "/Users/$user_name" NFSHomeDirectory \
    | /usr/bin/awk '{print $2}')"
  user_trash="$user_home/.Trash"
  case "$user_trash" in
    /Users/*/.Trash) ;;
    *) echo "refusing unexpected Trash path: $user_trash" >&2; exit 1 ;;
  esac
  backup="$user_trash/Nyra-$timestamp.app"
  /bin/mv "$TARGET_APP" "$backup"
  echo "Previous app moved to $backup"
fi

TEMP_ROOT="$(/usr/bin/mktemp -d '/Applications/.nyra-install.XXXXXX')"
/usr/bin/ditto "$SOURCE_APP" "$TEMP_ROOT/Nyra.app"
validate_owned_bundle "$TEMP_ROOT/Nyra.app"
/usr/bin/codesign --verify --deep --strict "$TEMP_ROOT/Nyra.app"
/bin/mv "$TEMP_ROOT/Nyra.app" "$TARGET_APP"
/usr/bin/codesign --verify --deep --strict "$TARGET_APP"
/usr/bin/open -n "$TARGET_APP"

for _ in {1..30}; do
  /usr/bin/pgrep -x Nyra >/dev/null 2>&1 && break
  /bin/sleep 0.1
done
/usr/bin/pgrep -x Nyra >/dev/null
echo "Installed and launched $TARGET_APP"
