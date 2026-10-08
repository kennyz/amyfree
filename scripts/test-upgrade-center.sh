#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/build"
swiftc "$REPO/app/UpdateModel.swift" "$REPO/app/AppUpdater.swift" "$REPO/app/AppRuntime.swift" "$REPO/app/UpgradeProcess.swift" "$REPO/app/UpgradeCenter.swift" "$REPO/tests/upgrade-center/main.swift" \
  -module-cache-path "${TMPDIR:-/tmp}/mihomo-swift-cache" -framework AppKit -framework Security -o "$REPO/build/upgrade-center-tests"
"$REPO/build/upgrade-center-tests"
