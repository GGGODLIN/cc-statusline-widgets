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

ps_out=$(ps -axo uid,pid,ppid,tty,pcpu,rss,etime,comm 2>/dev/null) || exit 0

orphan_count=0
hot_count=0

while IFS=$'\t' read -r kind pid cmd; do
  [[ -n "$kind" ]] || continue
  if [[ "$kind" == "hot" ]]; then
    hot_count=$(( hot_count + 1 ))
    continue
  fi
  full_cmd=$(ps -p "$pid" -o command= 2>/dev/null | head -1)
  [[ -n "$full_cmd" ]] || continue
  lsof_out=$(lsof -p "$pid" 2>/dev/null || true)
  revoked=$(printf '%s\n' "$lsof_out" | command grep -c "(revoked)" || true)
  cc_out=$(printf '%s\n' "$lsof_out" | awk '/\/(private\/)?tmp\/claude-[0-9]+\/.*\/tasks\/[^ ]+\.output$/ { print $NF; exit }')
  if (( ${revoked:-0} >= 2 )) || [[ -n "$cc_out" ]]; then
    orphan_count=$(( orphan_count + 1 ))
    continue
  fi
  case "$full_cmd" in
    *"/.claude/scripts/cc-statusline/daemon.sh"*|*"/.claude/scripts/cc-statusline/session-account-receiver.py"*|*"/.claude/hooks/projects-tripwire.sh"*|*"/.local/libexec/tokenbar-sampler/"*|*"/.litellm-venv/bin/litellm"*|*"/.magpie-machine/bin/"*|*"/.magpie-machine/native-bin/"*|*"/bin/semble"*|*"/Library/Input Methods/0c.app/"*|*"/Library/DevSpace/"*|*"/Applications/ChatGPT.app/"*|*"chrome-devtools-mcp"*|*"scripts/native_client_offline.py"*|*"scripts/playtest_monitor.py"*|*"scripts/playtest_player_runner.py"*)
      continue ;;
  esac
  if [[ "$kind" == "orphan_tool" ]]; then
    orphan_count=$(( orphan_count + 1 ))
    continue
  fi
  if [[ "$kind" == "orphan_runtime" || "$kind" == "orphan_runtime_giant" ]]; then
    is_stdin_orphan=$(awk '
      {
        c = $1; sub(/^.*\//, "", c)
        if (c !~ /^([Pp]ython[0-9.]*|node|bun)$/) exit 1
        if (NF < 2 || $NF != "-") exit 1
        for (i = 2; i < NF; i++) {
          if ($i !~ /^-[A-Za-z]+$/) exit 1
        }
        print 1; exit 0
      }
    ' <<<"$full_cmd" 2>/dev/null || echo 0)
    if (( ${is_stdin_orphan:-0} == 1 )); then
      orphan_count=$(( orphan_count + 1 ))
    elif [[ "$kind" == "orphan_runtime_giant" ]]; then
      hot_count=$(( hot_count + 1 ))
    fi
  fi
done < <(printf '%s\n' "$ps_out" | awk -v skip_age="${ORPHAN_SKIP_MIN_AGE:-0}" '
  NR == 1 { next }
  $1 == 501 {
    pid  = $2
    ppid = $3 + 0
    tty  = $4
    pcpu = $5 + 0
    rss  = $6 + 0
    et   = $7
    cmd  = $8
    sub(/^.*\//, "", cmd)
    sub(/^-/, "", cmd)

    is_shell   = (cmd ~ /^(zsh|bash|fish)$/)
    is_tool    = (cmd ~ /^(grep|ugrep|rg|find|fd|bfs|tail)$/)
    is_runtime = (cmd ~ /^([Pp]ython([0-9.]*)?|node|bun)$/)
    if (!is_shell && !is_tool && !is_runtime) next

    if (skip_age != 1 && et ~ /^0?[01]:[0-9][0-9]$/) next

    long_6h  = (et ~ /-/ || (et ~ /^[0-9]+:[0-9]+:[0-9]+$/ && substr(et, 1, index(et, ":") - 1) + 0 >= 6))
    long_20h = (et ~ /-/ || (et ~ /^[0-9]+:[0-9]+:[0-9]+$/ && substr(et, 1, index(et, ":") - 1) + 0 >= 20))

    if (ppid == 1 && tty == "??") {
      if (is_shell && pcpu >= 25) {
        printf "orphan_shell\t%s\t%s\n", pid, cmd
      } else if (is_tool && (pcpu >= 25 || long_6h)) {
        printf "orphan_tool\t%s\t%s\n", pid, cmd
      } else if (is_runtime && rss >= 4194304) {
        printf "orphan_runtime_giant\t%s\t%s\n", pid, cmd
      } else if (is_runtime && (pcpu >= 25 || rss >= 1048576)) {
        printf "orphan_runtime\t%s\t%s\n", pid, cmd
      }
    }
    if ((is_shell || is_tool) && pcpu > 80 && long_20h) {
      printf "hot\t%s\t%s\n", pid, cmd
    }
  }
')

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
