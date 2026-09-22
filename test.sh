#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CLT_ROOT="/Library/Developer/CommandLineTools"
XCODE_ROOT="/Applications/Xcode.app/Contents/Developer"
APP_BUNDLE="$ROOT_DIR/.build/app/Nyra.app"

cd "$ROOT_DIR"
if test -d "$XCODE_ROOT"; then
  export DEVELOPER_DIR="$XCODE_ROOT"
  SWIFT=(/usr/bin/xcrun swift)
  TEST_TOOLCHAIN_ARGS=(--scratch-path "$ROOT_DIR/.build/tests-xcode")
else
  SWIFT=(/usr/bin/swift)
  TEST_TOOLCHAIN_ARGS=(
    -Xswiftc -F -Xswiftc "$CLT_ROOT/Library/Developer/Frameworks"
    -Xlinker -F -Xlinker "$CLT_ROOT/Library/Developer/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/Frameworks"
    -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/usr/lib"
  )
fi

"${SWIFT[@]}" test \
  --disable-sandbox \
  "${TEST_TOOLCHAIN_ARGS[@]}" \
  "$@"

if test "$#" -eq 0; then
  "${SWIFT[@]}" build -c release --product Nyra
  "$ROOT_DIR/Scripts/build-app.sh" >/dev/null
  /usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

  if rg -n 'AVAudioFile|write\(to:|\.wav|\.m4a|\.caf' Sources/CodexVoice/Speech; then
    echo "privacy check failed: persistent audio code detected" >&2
    exit 1
  fi
  if rg -n 'auth\.json|accessToken|apiKey|browser.*cookie|JWT' Sources/CodexVoice; then
    echo "privacy check failed: credential-reading code detected" >&2
    exit 1
  fi
  if pgrep -fl 'Tests/Fixtures/fake-app-server.py'; then
    echo "process check failed: fake app-server is still running" >&2
    exit 1
  fi
  echo "Nyra verification passed"
fi
