#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/build"
swiftc "$REPO/app/UpdateModel.swift" "$REPO/tests/update/main.swift" \
  -module-cache-path "${TMPDIR:-/tmp}/mihomo-swift-cache" -o "$REPO/build/update-tests"
"$REPO/build/update-tests"
