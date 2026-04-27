#!/usr/bin/env bash
# cc-statusline-widgets wrapper
# Invoked by CC as statusLine.command. Reads stdin JSON, renders 3 lines.
set -uo pipefail

CACHE_DIR=/tmp/cc-widget-cache

CYAN=$'\033[38;5;30m'
BLUE=$'\033[38;5;111m'
GREEN=$'\033[38;5;70m'
YELLOW=$'\033[38;5;178m'
RED=$'\033[38;5;160m'
GRAY=$'\033[38;5;243m'
RST=$'\033[0m'

input=$(cat)
jqr() { jq -r "$1" <<<"$input" 2>/dev/null; }

# ----- Line 1 -----
model_name=$(jqr '.model.display_name // (if (.model | type) == "string" then .model else "?" end)')
session_cost_usd=$(jqr '.cost.total_cost_usd // 0')
session_cost_fmt=$(awk -v c="$session_cost_usd" 'BEGIN { printf "Cost: $%.2f", c }')

cwd=$(jqr '.workspace.current_dir // .cwd // ""')

git_branch_fmt="⎇ no git"
git_ab_fmt="(no git)"
if [[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "?")
  git_branch_fmt="⎇ $branch"
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [[ -n "$upstream" ]]; then
    ahead=$(git rev-list --count "$upstream"..HEAD 2>/dev/null || echo 0)
    behind=$(git rev-list --count HEAD.."$upstream" 2>/dev/null || echo 0)
    git_ab_fmt="${ahead}↑ ${behind}↓"
  else
    git_ab_fmt="(no upstream)"
  fi
fi

skills_fmt="Skill: -"

# session-clock from transcript first timestamp
transcript=$(jqr '.transcript_path // ""')
session_clock_fmt="Session: -"
if [[ -n "$transcript" && -f "$transcript" ]]; then
  first_ts=$(head -n 1 "$transcript" 2>/dev/null | jq -r '.timestamp // ""' 2>/dev/null || true)
  if [[ -n "$first_ts" ]]; then
    ts_trim="${first_ts:0:19}"
    first_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ts_trim" +%s 2>/dev/null || echo "")
    if [[ -n "$first_epoch" ]]; then
      now=$(date +%s)
      elapsed=$(( now - first_epoch ))
      (( elapsed < 0 )) && elapsed=0
      h=$(( elapsed / 3600 ))
      m=$(( (elapsed % 3600) / 60 ))
      if (( h > 0 )); then
        session_clock_fmt="Session: ${h}h ${m}m"
      else
        session_clock_fmt="Session: ${m}m"
      fi
    fi
  fi
fi

line1="${CYAN}Model: $model_name${RST} | ${GRAY}$skills_fmt${RST} | $git_branch_fmt $git_ab_fmt | ${GREEN}$session_cost_fmt${RST} | ${YELLOW}$session_clock_fmt${RST}"

# ----- Line 2: quota (delegate to existing usage-color.sh) -----
if [[ -x "$HOME/.claude/scripts/usage-color.sh" ]]; then
  line2=$("$HOME/.claude/scripts/usage-color.sh" 2>/dev/null || echo "")
else
  line2=""
fi

# ----- Line 3 -----
# context-bar
ctx_used_pct=$(jqr '.context_window.used_percentage // 0')
ctx_used_int=$(awk -v p="$ctx_used_pct" 'BEGIN { printf "%.0f", p }')
ctx_size=$(jqr '.context_window.context_window_size // 0')
ctx_used_tokens=$(jqr '
  (.context_window.current_usage.input_tokens // 0) +
  (.context_window.current_usage.cache_creation_input_tokens // 0) +
  (.context_window.current_usage.cache_read_input_tokens // 0)
')
if (( ctx_size > 0 )); then
  ctx_used_k=$(( ctx_used_tokens / 1000 ))
  ctx_total_k=$(( ctx_size / 1000 ))
else
  ctx_used_k=0
  ctx_total_k=0
fi

bar_width=16
bar_filled=$(( ctx_used_int * bar_width / 100 ))
(( bar_filled > bar_width )) && bar_filled=$bar_width
(( bar_filled < 0 )) && bar_filled=0
bar=""
i=0
while (( i < bar_width )); do
  if (( i < bar_filled )); then bar="${bar}█"
  else bar="${bar}░"
  fi
  i=$(( i + 1 ))
done
ctx_bar_fmt="${bar} ${ctx_used_k}k/${ctx_total_k}k (${ctx_used_int}%)"

# tokens-total
tokens_total=$(jqr '
  (.context_window.current_usage.input_tokens // 0) +
  (.context_window.current_usage.output_tokens // 0) +
  (.context_window.current_usage.cache_creation_input_tokens // 0) +
  (.context_window.current_usage.cache_read_input_tokens // 0)
')
if (( tokens_total >= 1000 )); then
  tokens_fmt=$(awk -v t="$tokens_total" 'BEGIN { printf "Total: %.1fk", t/1000 }')
else
  tokens_fmt="Total: ${tokens_total}"
fi

# read daemon-written widgets
free_mem=$(cat "$CACHE_DIR/memory.txt" 2>/dev/null || printf 'Mem: ?')
disk=$(cat "$CACHE_DIR/disk.txt" 2>/dev/null || printf '💾 ?')
battery=$(cat "$CACHE_DIR/battery.txt" 2>/dev/null || printf '🔋?')

line3="${BLUE}$ctx_bar_fmt${RST} | $tokens_fmt | $free_mem | $disk | $battery"

if [[ -n "$line2" ]]; then
  printf '%s\n%s\n%s\n' "$line1" "$line2" "$line3"
else
  printf '%s\n%s\n' "$line1" "$line3"
fi
