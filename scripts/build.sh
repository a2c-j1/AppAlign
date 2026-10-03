#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/setup.sh"
xcodebuild \
  -project AppAlign.xcodeproj \
  -scheme AppAlign \
  -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/build/DerivedData" \
  build
