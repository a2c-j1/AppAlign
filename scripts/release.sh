#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
"$ROOT/scripts/setup.sh"

VERSION="${1:-$(git describe --tags --always --dirty)}"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/AppAlign.xcarchive"
APP="$ARCHIVE/Products/Applications/AppAlign.app"
ZIP="$OUT/AppAlign-$VERSION-macos.zip"

mkdir -p "$OUT"
xcodebuild \
  -project AppAlign.xcodeproj \
  -scheme AppAlign \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$ROOT/build/ArchiveDerivedData" \
  -archivePath "$ARCHIVE" \
  CODE_SIGNING_ALLOWED=NO \
  archive

[[ -d "$APP" ]] || { echo "Archived app bundle is missing: $APP" >&2; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"
echo "Release artifacts: $ZIP and $ZIP.sha256"
