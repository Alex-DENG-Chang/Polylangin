#!/bin/bash
# Zip today's (or all) Polylangin typing logs so they can be moved to another machine.
set -euo pipefail
SRC="$HOME/Desktop/Polylangin-logs"
if [ ! -d "$SRC" ]; then
  SRC="$HOME/Library/Logs/Polylangin"
fi
OUT="$HOME/Desktop/Polylangin-typing-logs-$(date +%Y%m%d-%H%M).zip"
[ -d "$SRC" ] || { echo "no logs at $SRC" >&2; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$SRC" "$OUT"
echo "wrote $OUT"
