#!/usr/bin/env bash
# free-memory.sh: macOS memory usage as 'Mem: USED_G/TOTAL_G'
# Aligned with ccstatusline FreeMemory.ts: htop-style (active + wired)
set -euo pipefail

CYAN=$'\033[38;5;30m'
RST=$'\033[0m'

total_bytes=$(sysctl -n hw.memsize)
total_gb=$(awk -v t="$total_bytes" 'BEGIN { printf "%.1f", t/1024/1024/1024 }')

vm=$(vm_stat 2>/dev/null | tr -d '.')
page_size=$(printf '%s' "$vm" | head -n 1 | grep -oE '[0-9]+' | head -n 1)
[[ -z "${page_size:-}" ]] && page_size=4096

# htop-style: used = (active + wired) * page_size
active=$(printf '%s' "$vm" | awk '/Pages active/ {print $3; exit}')
wired=$(printf '%s' "$vm" | awk '/Pages wired down/ {print $4; exit}')
active=${active:-0}
wired=${wired:-0}

used_pages=$(( active + wired ))
used_bytes=$(( used_pages * page_size ))
used_gb=$(awk -v u="$used_bytes" 'BEGIN { printf "%.1f", u/1024/1024/1024 }')

printf '%sMem: %sG/%sG%s' "$CYAN" "$used_gb" "$total_gb" "$RST"
