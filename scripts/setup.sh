#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "AppAlign requires macOS and Xcode." >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode command line tools are required. Install/select Xcode, then retry." >&2
  exit 1
fi

xcodebuild -version
xcodebuild -resolvePackageDependencies -project AppAlign.xcodeproj -scheme AppAlign
mkdir -p build
echo "AppAlign setup complete."
