#!/usr/bin/env bash
# cc-statusline-widgets daemon
# Runs under launchd KeepAlive. Each widget has its own cycle.
set -uo pipefail

# launchd starts us with a minimal PATH; extend so widgets can find brew tools.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CACHE_DIR="${CC_WIDGET_CACHE_DIR:-/tmp/cc-widget-cache}"
mkdir -p "$CACHE_DIR"

LOCK_DIR="$CACHE_DIR/.daemon.lock"
LOCK_PID_FILE="$LOCK_DIR/pid"

acquire_lock() {
  local attempt=0 holder=""
  while (( attempt < 3 )); do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCK_PID_FILE"
      return 0
    fi
    sleep 0.05 2>/dev/null || sleep 1
    holder=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
    if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
      return 1
    fi
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    attempt=$(( attempt + 1 ))
  done
  return 1
}

if ! acquire_lock; then
  exit 0
fi

# Spec: name|cmd|cycle_seconds (bash 3.2 compatible — no associative array)
if [[ -n "${DAEMON_WIDGETS_OVERRIDE:-}" ]]; then
  WIDGETS=()
  while IFS= read -r _w_line; do
    [[ -n "${_w_line// }" ]] && WIDGETS+=("$_w_line")
  done <<<"$DAEMON_WIDGETS_OVERRIDE"
else
  WIDGETS=(
    "battery|/Users/linhancheng/.claude/scripts/cc-statusline-battery.sh|1"
    "disk|/Users/linhancheng/.claude/scripts/disk-usage.sh|60"
    "memory|/Users/linhancheng/.claude/scripts/cc-statusline/free-memory.sh|5"
    "cpu|/Users/linhancheng/.claude/scripts/cc-statusline/cpu-usage.sh|5"
    "thermals|/Users/linhancheng/.claude/scripts/cc-statusline/thermals.sh|5"
    "runaway|/Users/linhancheng/.claude/scripts/cc-statusline/runaway.sh|10"
    "grok-bot|/Users/linhancheng/.claude/scripts/cc-statusline/grok-bot-usage.mjs|300"
    "devin-pool|/Users/linhancheng/.claude/scripts/cc-statusline/devin-pool-usage.mjs|60"
    "codex-pool|/Users/linhancheng/.claude/scripts/cc-statusline/codex-pool-usage.mjs|30"
  )
fi

write_atomic() {
  local path=$1 content=$2 tmp
  tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || return 1
  if printf '%s' "$content" > "$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

write_json_companion() {
  local name="$1" plain="$2" ts="$3" tmp
  tmp=$(mktemp "$CACHE_DIR/.${name}.json.XXXXXX" 2>/dev/null) || return 1
  if python3 -c "
import json, sys
print(json.dumps({'display': sys.argv[1], 'ts': int(sys.argv[2])}))
" "$plain" "$ts" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE_DIR/$name.json" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

BG_PIDS=()

kill_tree() {
  local p=$1 c
  for c in $(pgrep -P "$p" 2>/dev/null || true); do
    kill_tree "$c"
  done
  kill "$p" 2>/dev/null || true
}

cleanup() {
  local pid owner
  if (( ${#BG_PIDS[@]} > 0 )); then
    for pid in "${BG_PIDS[@]}"; do
      pkill -P "$pid" 2>/dev/null || true
      kill_tree "$pid"
      wait "$pid" 2>/dev/null || true
    done
  fi
  if [[ -f "$LOCK_PID_FILE" ]]; then
    owner=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
    if [[ "$owner" == "$$" ]]; then
      rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
}

trap cleanup EXIT
trap 'exit 0' INT TERM

# Background mactop loop: feeds fan RPM cache for thermals widget.
# mactop has ~5s cold start, so we run it isolated from the main per-widget loop.
if command -v mactop >/dev/null 2>&1; then
  (
    child=""
    trap '[[ -n "$child" ]] && kill_tree "$child"; exit 0' INT TERM EXIT
    while true; do
      if raw_f=$(mktemp "$CACHE_DIR/.mactop-raw.XXXXXX" 2>/dev/null); then
        mactop --headless --count 1 --format json > "$raw_f" 2>/dev/null &
        child=$!
        wait "$child" 2>/dev/null || true
        child=""
        if [[ -s "$raw_f" ]]; then
          mv -f "$raw_f" "$CACHE_DIR/.mactop-fan.json" 2>/dev/null || rm -f "$raw_f"
        else
          rm -f "$raw_f"
        fi
      fi
      sleep 30 &
      child=$!
      wait "$child" 2>/dev/null || true
      child=""
    done
  ) &
  BG_PIDS+=($!)
fi

# Background macmon stream: feeds CPU/GPU temp cache for thermals widget.
# Long-lived `-s 0 -i 5000` avoids the spawn + 200ms busy-poll cost per refresh.
# Outer `while true` is a watchdog: if macmon dies the pipe closes, inner loop
# exits, and we respawn after 5s — otherwise the cache would silently freeze.
if command -v macmon >/dev/null 2>&1; then
  (
    child=""
    trap '[[ -n "$child" ]] && kill_tree "$child"; exit 0' INT TERM EXIT
    while true; do
      (
        trap 'pkill -P $$ 2>/dev/null || true; exit 0' INT TERM EXIT
        macmon pipe -s 0 -i 5000 2>/dev/null | while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          if tmp_f=$(mktemp "$CACHE_DIR/.macmon-temp.json.XXXXXX" 2>/dev/null); then
            printf '%s' "$line" > "$tmp_f" 2>/dev/null && mv -f "$tmp_f" "$CACHE_DIR/.macmon-temp.json" 2>/dev/null || rm -f "$tmp_f"
          fi
        done
      ) &
      child=$!
      wait "$child" 2>/dev/null || true
      child=""
      sleep 5 &
      child=$!
      wait "$child" 2>/dev/null || true
      child=""
    done
  ) &
  BG_PIDS+=($!)
fi

# Background OTLP receiver: maps CC session.id -> user.email so usage-color.sh
# can name the account THIS session actually burns (CC 憑證是 per-process 的，
# $HOME/.claude.json 只記最後一次登入誰). Same watchdog shape as macmon above.
RECEIVER="$(dirname "$0")/session-account-receiver.py"
if [[ -f "$RECEIVER" ]]; then
  (
    child=""
    trap '[[ -n "$child" ]] && kill "$child" 2>/dev/null; exit 0' INT TERM EXIT
    while true; do
      python3 "$RECEIVER" >/dev/null 2>&1 &
      child=$!
      wait "$child" 2>/dev/null || true
      child=""
      sleep 5 &
      child=$!
      wait "$child" 2>/dev/null || true
      child=""
    done
  ) &
  BG_PIDS+=($!)
fi

while true; do
  now=$(date +%s)
  for spec in ${WIDGETS[@]+"${WIDGETS[@]}"}; do
    name="${spec%%|*}"
    rest="${spec#*|}"
    cmd="${rest%|*}"
    cycle="${rest##*|}"
    last_file="$CACHE_DIR/.last-$name"
    last=$(cat "$last_file" 2>/dev/null || echo 0)
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    (( now < last )) && last=0
    if (( now - last >= cycle )); then
      if [[ -x "$cmd" ]]; then
        out=$("$cmd" 2>/dev/null) || true
        # Always write cache (even empty) so conditional widgets like
        # runaway can clear stale alerts when the situation resolves.
        write_atomic "$CACHE_DIR/$name.txt" "$out" || true
        plain=$(printf '%s' "$out" | sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g')
        write_json_companion "$name" "$plain" "$(date +%s)" || true
      fi
      write_atomic "$last_file" "$now" || true
    fi
  done
  sleep 1 &
  wait $! 2>/dev/null || true
done
