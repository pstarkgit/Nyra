#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CLT_ROOT="/Library/Developer/CommandLineTools"
APP_BUNDLE="$ROOT_DIR/.build/app/Codex Voice.app"

cd "$ROOT_DIR"
swift test \
  --disable-sandbox \
  -Xswiftc -F -Xswiftc "$CLT_ROOT/Library/Developer/Frameworks" \
  -Xlinker -F -Xlinker "$CLT_ROOT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/usr/lib" \
  "$@"

if test "$#" -eq 0; then
  swift build -c release --product CodexVoice
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
  echo "Codex Voice verification passed"
fi
