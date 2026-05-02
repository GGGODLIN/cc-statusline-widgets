#!/usr/bin/env bash
# cc-statusline-widgets daemon
# Runs under launchd KeepAlive. Each widget has its own cycle.
set -uo pipefail

# launchd starts us with a minimal PATH; extend so widgets can find brew tools.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CACHE_DIR=/tmp/cc-widget-cache
mkdir -p "$CACHE_DIR"

# Spec: name|cmd|cycle_seconds (bash 3.2 compatible — no associative array)
WIDGETS=(
  "battery|/Users/linhancheng/.claude/scripts/cc-statusline-battery.sh|1"
  "disk|/Users/linhancheng/.claude/scripts/disk-usage.sh|60"
  "memory|/Users/linhancheng/.claude/scripts/cc-statusline/free-memory.sh|5"
  "cpu|/Users/linhancheng/.claude/scripts/cc-statusline/cpu-usage.sh|5"
  "thermals|/Users/linhancheng/.claude/scripts/cc-statusline/thermals.sh|5"
)

write_atomic() {
  local path=$1 content=$2
  printf '%s' "$content" > "${path}.tmp" && mv "${path}.tmp" "$path"
}

write_json_companion() {
  local name="$1" plain="$2" ts="$3"
  python3 -c "
import json, sys
print(json.dumps({'display': sys.argv[1], 'ts': int(sys.argv[2])}))
" "$plain" "$ts" > "$CACHE_DIR/$name.json.tmp.$$" \
    && mv "$CACHE_DIR/$name.json.tmp.$$" "$CACHE_DIR/$name.json"
}

# Background mactop loop: feeds fan RPM cache for thermals widget.
# mactop has ~5s cold start, so we run it isolated from the main per-widget loop.
if command -v mactop >/dev/null 2>&1; then
  (
    while true; do
      out=$(mactop --headless --count 1 --format json 2>/dev/null) || true
      if [[ -n "$out" ]]; then
        printf '%s' "$out" > "$CACHE_DIR/.mactop-fan.json.tmp" \
          && mv "$CACHE_DIR/.mactop-fan.json.tmp" "$CACHE_DIR/.mactop-fan.json"
      fi
      sleep 30
    done
  ) &
  MACTOP_BG_PID=$!
  trap 'kill "$MACTOP_BG_PID" 2>/dev/null' EXIT INT TERM
fi

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
          plain=$(printf '%s' "$out" | sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g')
          write_json_companion "$name" "$plain" "$(date +%s)" || true
        fi
      fi
      echo "$now" > "$last_file"
    fi
  done
  sleep 1
done
