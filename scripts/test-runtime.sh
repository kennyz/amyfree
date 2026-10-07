#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/build"
swiftc "$REPO/app/AppRuntime.swift" "$REPO/tests/runtime/main.swift" \
  -module-cache-path "${TMPDIR:-/tmp}/mihomo-swift-cache" -framework Security \
  -o "$REPO/build/runtime-tests"
"$REPO/build/runtime-tests"
