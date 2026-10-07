#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/build"
swiftc "$REPO/app/NodeProbeModel.swift" "$REPO/tests/probe/main.swift" \
  -module-cache-path "${TMPDIR:-/tmp}/mihomo-swift-cache" -o "$REPO/build/probe-tests"
"$REPO/build/probe-tests"
