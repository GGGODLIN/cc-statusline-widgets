#!/usr/bin/env bash
# thermals.sh: CPU/GPU temp via macmon (~200ms) + fan RPM from mactop cache.
# Apple Silicon only. Requires: brew install macmon mactop.
# Fan RPM cache is refreshed every 30s by daemon's background mactop loop.
set -uo pipefail

CACHE_DIR=/tmp/cc-widget-cache
FAN_CACHE="$CACHE_DIR/.mactop-fan.json"

GREEN=$'\033[38;5;70m'
BLUE=$'\033[38;5;111m'
YELLOW=$'\033[38;5;178m'
RED=$'\033[38;5;160m'
RED_BOLD=$'\033[1;38;5;160m'
GRAY=$'\033[38;5;243m'
RST=$'\033[0m'

json=$(macmon pipe -s 1 -i 200 2>/dev/null || true)
cpu_t=$(jq -r '.temp.cpu_temp_avg // 0' <<<"$json" 2>/dev/null || echo 0)
gpu_t=$(jq -r '.temp.gpu_temp_avg // 0' <<<"$json" 2>/dev/null || echo 0)
cpu_t_int=$(awk -v t="$cpu_t" 'BEGIN { printf "%d", t }')
gpu_t_int=$(awk -v t="$gpu_t" 'BEGIN { printf "%d", t }')

fan_rpm=0
fan_pct=0
fan_str="?"
if [[ -f "$FAN_CACHE" ]]; then
  # Pick the fan currently spinning fastest; pull its min/max from the same record.
  fan_line=$(jq -r '
    (.[0].fans // [])
    | sort_by(-(.rpm // 0))
    | (.[0] // {})
    | "\(.rpm // 0) \(.min_rpm // 0) \(.max_rpm // 0)"
  ' "$FAN_CACHE" 2>/dev/null || echo "0 0 0")
  read -r fan_rpm fan_min fan_max <<<"$fan_line"
  fan_rpm=${fan_rpm:-0}
  fan_min=${fan_min:-0}
  fan_max=${fan_max:-0}
  if (( fan_max > fan_min && fan_rpm > 0 )); then
    fan_pct=$(awk -v r="$fan_rpm" -v lo="$fan_min" -v hi="$fan_max" 'BEGIN {
      p = (r - lo) / (hi - lo) * 100
      if (p < 0) p = 0
      if (p > 100) p = 100
      printf "%d", p
    }')
    fan_str=$(awk -v r="$fan_rpm" -v p="$fan_pct" 'BEGIN { printf "%.1fk (%d%%)", r/1000, p }')
  fi
fi

if   (( cpu_t_int >= 95 )); then temp_color=$RED_BOLD
elif (( cpu_t_int >= 85 )); then temp_color=$RED
elif (( cpu_t_int >= 75 )); then temp_color=$YELLOW
elif (( cpu_t_int >= 60 )); then temp_color=$BLUE
else                              temp_color=$GREEN
fi

# Fan color by normalized speed: (rpm - min_rpm) / (max_rpm - min_rpm).
# Min/max come from SMC via mactop, so this auto-calibrates per machine.
if   (( fan_pct >= 90 )); then fan_color=$RED_BOLD
elif (( fan_pct >= 75 )); then fan_color=$RED
elif (( fan_pct >= 50 )); then fan_color=$YELLOW
elif (( fan_pct >= 25 )); then fan_color=$BLUE
elif (( fan_rpm >  0 )); then fan_color=$GREEN
else                            fan_color=$GRAY
fi

if (( cpu_t_int == 0 )); then
  printf '%s🌡️ ?%s' "$GRAY" "$RST"
else
  printf '%s🌡️ %d°/%d°%s %s💨 %s%s' "$temp_color" "$cpu_t_int" "$gpu_t_int" "$RST" "$fan_color" "$fan_str" "$RST"
fi
