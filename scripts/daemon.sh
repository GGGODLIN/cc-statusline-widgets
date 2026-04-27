#!/usr/bin/env bash
# cc-statusline-widgets daemon
# Runs under launchd KeepAlive. Each widget has its own cycle.
set -uo pipefail

CACHE_DIR=/tmp/cc-widget-cache
mkdir -p "$CACHE_DIR"

# Spec: name|cmd|cycle_seconds (bash 3.2 compatible — no associative array)
WIDGETS=(
  "battery|/Users/linhancheng/.claude/scripts/cc-statusline-battery.sh|1"
  "disk|/Users/linhancheng/.claude/scripts/disk-usage.sh|60"
  "memory|/Users/linhancheng/.claude/scripts/cc-statusline/free-memory.sh|5"
)

write_atomic() {
  local path=$1 content=$2
  printf '%s' "$content" > "${path}.tmp" && mv "${path}.tmp" "$path"
}

while true; do
  now=$(date +%s)
  for spec in "${WIDGETS[@]}"; do
    name="${spec%%|*}"
    rest="${spec#*|}"
    cmd="${rest%|*}"
    cycle="${rest##*|}"
    last_file="$CACHE_DIR/.last-$name"
    last=$(cat "$last_file" 2>/dev/null || echo 0)
    if (( now - last >= cycle )); then
      if [[ -x "$cmd" ]]; then
        out=$("$cmd" 2>/dev/null) || true
        if [[ -n "$out" ]]; then
          write_atomic "$CACHE_DIR/$name.txt" "$out"
        fi
      fi
      echo "$now" > "$last_file"
    fi
  done
  sleep 1
done
