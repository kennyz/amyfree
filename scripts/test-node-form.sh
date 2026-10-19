#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/build"
swiftc "$REPO/app/L10n.swift" "$REPO/app/NodeForm.swift" "$REPO/app/NodeImport.swift" "$REPO/tests/node-form/main.swift" \
  -module-cache-path "${TMPDIR:-/tmp}/mihomo-swift-cache" -o "$REPO/build/node-form-tests"
"$REPO/build/node-form-tests" -AmyfreeLanguage zh
