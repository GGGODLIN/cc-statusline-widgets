#!/usr/bin/env bash
# runaway.sh: runaway / orphan shell early-warning widget for cc-statusline-widgets
#
# Two tiers:
#   Tier 1 (orphan):  ppid=1 + tty=?? + comm is shell  → 🚨 (red)
#   Tier 2 (hot):     %CPU>80 + etime contains days or 20h+ + shell  → ⚠️ (yellow)
#
# Empty output means "all clear, hide widget" (paired with daemon always-write).
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

RED=$'\033[38;5;160m'
YELLOW=$'\033[38;5;178m'
RST=$'\033[0m'

ps_out=$(ps -axo pid,ppid,tty,pcpu,etime,comm 2>/dev/null) || exit 0

# Tier 1: orphan zsh fingerprint
orphan_count=$(printf '%s\n' "$ps_out" |
  awk '$2==1 && $3=="??" && $6 ~ /^-?(zsh|bash|fish)$/' | wc -l | tr -d ' ')

# Tier 2: high-CPU long-running shell (etime D+:HH:MM:SS or HH:MM:SS with H>=20)
hot_count=$(printf '%s\n' "$ps_out" |
  awk '$4 > 80 && ($5 ~ /-/ || ($5 ~ /^[0-9]+:[0-9]+:[0-9]+$/ && substr($5,1,index($5,":")-1) >= 20)) && $6 ~ /^-?(zsh|bash|fish)$/' |
  wc -l | tr -d ' ')

out=""
if (( orphan_count > 0 )); then
  out="${RED}🚨 orphan×${orphan_count}${RST}"
fi
if (( hot_count > 0 )); then
  if [[ -n "$out" ]]; then
    out="${out} ${YELLOW}⚠️ hot×${hot_count}${RST}"
  else
    out="${YELLOW}⚠️ hot×${hot_count}${RST}"
  fi
fi

printf '%s' "$out"
