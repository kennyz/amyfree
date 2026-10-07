#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/build"
swiftc "$REPO/app/LoginStartup.swift" "$REPO/tests/login/main.swift" \
  -module-cache-path "${TMPDIR:-/tmp}/mihomo-swift-cache" \
  -framework ServiceManagement -o "$REPO/build/startup-tests"
"$REPO/build/startup-tests"
