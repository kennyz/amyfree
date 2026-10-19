#!/bin/bash
# Update and validate databases without interrupting current connections.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -x "$SELF_DIR/amyfree-helper" ]; then
  DEFAULT_DEST="$SELF_DIR"
else
  DEFAULT_DEST="$SELF_DIR/../mihomo"
fi
DEST="${1:-$DEFAULT_DEST}"
HELPER="$DEST/amyfree-helper"
if [ ! -x "$HELPER" ]; then
  echo "amyfree-helper not found in $DEST; build it with: cargo build --release" >&2
  exit 1
fi
exec "$HELPER" geodata --home "$DEST"
