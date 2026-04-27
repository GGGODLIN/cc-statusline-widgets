#!/usr/bin/env bash
# free-memory.sh: macOS memory usage as 'Mem: USED_G/TOTAL_G'
set -euo pipefail

CYAN=$'\033[38;5;30m'
RST=$'\033[0m'

total_bytes=$(sysctl -n hw.memsize)
total_gb=$(awk -v t="$total_bytes" 'BEGIN { printf "%.1f", t/1024/1024/1024 }')

vm=$(vm_stat 2>/dev/null | tr -d '.')
page_size=$(printf '%s' "$vm" | head -n 1 | grep -oE '[0-9]+' | head -n 1)
[[ -z "${page_size:-}" ]] && page_size=4096

free=$(printf '%s' "$vm" | awk '/Pages free/ {print $3; exit}')
inactive=$(printf '%s' "$vm" | awk '/Pages inactive/ {print $3; exit}')
spec=$(printf '%s' "$vm" | awk '/Pages speculative/ {print $3; exit}')
free=${free:-0}; inactive=${inactive:-0}; spec=${spec:-0}

free_pages=$(( free + inactive + spec ))
free_bytes=$(( free_pages * page_size ))
used_bytes=$(( total_bytes - free_bytes ))
used_gb=$(awk -v u="$used_bytes" 'BEGIN { printf "%.1f", u/1024/1024/1024 }')

printf '%sMem: %sG/%sG%s' "$CYAN" "$used_gb" "$total_gb" "$RST"
