#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CLT_ROOT="/Library/Developer/CommandLineTools"

cd "$ROOT_DIR"
exec swift test \
  --disable-sandbox \
  -Xswiftc -F -Xswiftc "$CLT_ROOT/Library/Developer/Frameworks" \
  -Xlinker -F -Xlinker "$CLT_ROOT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT_ROOT/Library/Developer/usr/lib" \
  "$@"
