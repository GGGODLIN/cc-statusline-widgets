#!/usr/bin/env bash
# runaway.sh: runaway / orphan shell early-warning widget for cc-statusline-widgets
#
# Two tiers:
#   Tier 1 (orphan):  ppid=1 + tty=?? +
#                     ((shell|search-cli) with %CPU>=25, OR search/stream-cli with etime>=6h) → 🚨 (red)
#   Tier 2 (hot):     %CPU>80 + etime contains days or 20h+ + (shell|search-cli) → ⚠️ (yellow)
#
# Empty output means "all clear, hide widget" (paired with daemon always-write).
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

RED=$'\033[38;5;160m'
YELLOW=$'\033[38;5;178m'
RST=$'\033[0m'

ps_out=$(ps -axo pid,ppid,tty,pcpu,etime,comm 2>/dev/null) || exit 0

counts=$(printf '%s\n' "$ps_out" | awk '
  NR == 1 { next }
  {
    ppid = $2 + 0
    tty  = $3
    pcpu = $4 + 0
    et   = $5
    cmd  = $6
    sub(/^.*\//, "", cmd)
    sub(/^-/, "", cmd)

    is_shell = (cmd ~ /^(zsh|bash|fish)$/)
    is_tool  = (cmd ~ /^(grep|ugrep|rg|find|fd|bfs|tail)$/)
    if (!is_shell && !is_tool) next

    long_6h  = (et ~ /-/ || (et ~ /^[0-9]+:[0-9]+:[0-9]+$/ && substr(et, 1, index(et, ":") - 1) + 0 >= 6))
    long_20h = (et ~ /-/ || (et ~ /^[0-9]+:[0-9]+:[0-9]+$/ && substr(et, 1, index(et, ":") - 1) + 0 >= 20))

    if (ppid == 1 && tty == "??" && (pcpu >= 25 || (is_tool && long_6h))) {
      orphan++
    }
    if (pcpu > 80 && long_20h) {
      hot++
    }
  }
  END { printf "%d %d\n", orphan + 0, hot + 0 }
')
read -r orphan_count hot_count <<<"$counts"

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
