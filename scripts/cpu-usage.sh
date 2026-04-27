#!/usr/bin/env bash
# cpu-usage.sh: instant CPU% (user + sys) over 1-second interval
# Aligned with macOS Activity Monitor. Cost: ~1.01s (pure sleep).
set -euo pipefail

CYAN=$'\033[38;5;30m'
GREEN=$'\033[38;5;70m'
BLUE=$'\033[38;5;111m'
YELLOW=$'\033[38;5;178m'
RED=$'\033[38;5;160m'
RED_BOLD=$'\033[1;38;5;160m'
RST=$'\033[0m'

# iostat -c 2: 2 samples; -w 1: 1 second between samples; -n 0: skip disk columns
# Output:
#       cpu    load average
#  us sy id   1m   5m   15m
#  11  8 81  4.17 3.93 3.63   <- since-boot avg (ignored)
#   8  8 84  4.17 3.93 3.63   <- last 1s instant ← we want this
output=$(iostat -c 2 -w 1 -n 0 2>/dev/null | tail -1)
read us sy id _ <<<"$output"
us=${us:-0}; sy=${sy:-0}

pct=$(( us + sy ))

if   (( pct >= 80 )); then color=$RED_BOLD
elif (( pct >= 60 )); then color=$RED
elif (( pct >= 40 )); then color=$YELLOW
elif (( pct >= 20 )); then color=$BLUE
else                        color=$GREEN
fi

printf '%sCPU: %s%%%s' "$color" "$pct" "$RST"
