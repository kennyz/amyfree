#!/bin/bash
# Update and validate databases without interrupting current connections.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SELF_DIR/geodata_update.py" ]; then
  HELPER="$SELF_DIR/geodata_update.py"
  DEFAULT_DEST="$SELF_DIR"
else
  HELPER="$SELF_DIR/../mihomo/geodata_update.py"
  DEFAULT_DEST="$SELF_DIR/../mihomo"
fi
DEST="${1:-$DEFAULT_DEST}"
[ ! -x "$DEST/python3" ] || export PATH="$DEST:$PATH"
exec python3 "$HELPER" --home "$DEST"
