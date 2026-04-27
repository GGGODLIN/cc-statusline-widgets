#!/usr/bin/env bash
set -euo pipefail

WIDGET=battery
OUT=/tmp/cc-widget-$WIDGET.txt
TMP=$OUT.tmp
RENDER=/Users/linhancheng/.claude/scripts/cc-statusline-battery.sh
INTERVAL=5

while true; do
  if output=$("$RENDER" 2>/dev/null); then
    printf '%s' "$output" > "$TMP" && mv "$TMP" "$OUT"
  fi
  sleep "$INTERVAL"
done
