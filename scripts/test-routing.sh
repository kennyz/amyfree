#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/build"
swiftc "$REPO/app/RoutingModel.swift" "$REPO/tests/main.swift" \
  -module-cache-path "${TMPDIR:-/tmp}/mihomo-swift-cache" \
  -o "$REPO/build/routing-tests"
"$REPO/build/routing-tests"
