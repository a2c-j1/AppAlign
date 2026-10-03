#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "$ROOT/build" ]]; then
  rm -rf "$ROOT/build"
  echo "Removed generated build and release artifacts."
else
  echo "No generated artifacts to clean."
fi
