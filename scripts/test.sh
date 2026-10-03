#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build.sh"

APP="$ROOT/build/DerivedData/Build/Products/Debug/AppAlign.app"
[[ -d "$APP" ]] || { echo "App bundle is missing: $APP" >&2; exit 1; }
INFO="$APP/Contents/Info.plist"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")"

[[ -x "$APP/Contents/MacOS/$EXECUTABLE_NAME" ]] || { echo "App executable is missing or not executable." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "jp.a2c.AppAlign" ]] || {
  echo "Unexpected bundle identifier." >&2
  exit 1
}

echo "AppAlign build smoke checks passed."
