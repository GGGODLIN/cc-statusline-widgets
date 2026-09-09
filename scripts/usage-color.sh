#!/usr/bin/env bash

BLUE=$'\033[38;5;111m'
GREEN=$'\033[38;5;70m'
YELLOW=$'\033[38;5;178m'
RED=$'\033[38;5;160m'
RED_BOLD=$'\033[1;38;5;160m'
RST=$'\033[0m'

CACHE_DIR="$HOME/.claude/cache"

OLD_AFTER_SECONDS=${OLD_AFTER_SECONDS:-400}
STALE_AFTER_SECONDS=${STALE_AFTER_SECONDS:-600}

# 已結束的帳號：cache 仍可能被 fetcher 寫入，但不再渲染 pill。
# 格式 |email|email|，移除某行即恢復顯示。
EXCLUDE_EMAILS="|philip@akohub.com|qwe70301@gmail.com|philiplin@calyxtechs.com|"

color_for() {
  local v=${1%.*}
  if (( v >= 100 )); then printf '%s' "$RED_BOLD"
  elif (( v >= 80 )); then printf '%s' "$RED"
  elif (( v >= 50 )); then printf '%s' "$YELLOW"
  elif (( v >= 30 )); then printf '%s' "$BLUE"
  else printf '%s' "$GREEN"
  fi
}

fmt_name() {
  local prefix="${1%@*}"
  case "$prefix" in
    alex.robin)     printf 'Max' ;;
    software.agent) printf 'Team' ;;
    *)          printf '%s' "$prefix" ;;
  esac
}

fmt_reset() {
  local at="${1%%.*}"
  [[ -z "$at" ]] && { printf -- '—'; return; }
  local reset_s now_s diff_s
  reset_s=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$at" +%s 2>/dev/null) \
    || { printf -- '—'; return; }
  now_s=$(date +%s)
  diff_s=$((reset_s - now_s))
  (( diff_s < 0 )) && { printf -- '—'; return; }
  if (( diff_s >= 86400 )); then
    local d=$((diff_s / 86400)) h=$(((diff_s % 86400) / 3600)) m=$(((diff_s % 3600) / 60))
    printf '%dd%dh%dm' "$d" "$h" "$m"
  else
    date -r "$reset_s" "+%H:%M"
  fi
}

fmt_age() {
  local s=$1
  if (( s < 60 )); then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm' $((s / 60))
  elif (( s < 86400 )); then printf '%dh' $((s / 3600))
  else printf '%dd' $((s / 86400))
  fi
}

render_segment() {
  local email="$1" cache="$2"
  local status="${cache%.json}.status"

  if [[ -f "$status" ]]; then
    local ts msg
    IFS=$'\t' read -r ts msg < "$status"
    printf '%s%s | %s⚠ %s @ %s%s' "$BLUE" "$(fmt_name "$email")" "$RED" "$msg" "$ts" "$RST"
    return
  fi

  [[ ! -f "$cache" ]] && return
  local wu wr_at su sr_at fu
  wu=$(jq -r '.data.seven_day.utilization // 0' "$cache")
  wr_at=$(jq -r '.data.seven_day.resets_at // ""' "$cache")
  su=$(jq -r '.data.five_hour.utilization // 0' "$cache")
  sr_at=$(jq -r '.data.five_hour.resets_at // ""' "$cache")
  fu=$(jq -r '[.data.limits[]? | select(.kind == "weekly_scoped") | .percent] | max // empty' "$cache")
  local wc sc
  wc=$(color_for "$wu")
  sc=$(color_for "$su")
  local wu_fmt su_fmt fu_fmt weekly_part
  wu_fmt=$(printf '%.0f' "${wu:-0}")
  su_fmt=$(printf '%.0f' "${su:-0}")
  weekly_part=$(printf '%s%s%%%s' "$wc" "$wu_fmt" "$RST")
  if [[ -n "$fu" ]]; then
    fu_fmt=$(printf '%.0f' "$fu")
    if (( wu_fmt < 100 || fu_fmt < 100 )); then
      weekly_part+=$(printf '%s · %s%s%%%s' "$BLUE" "$(color_for "$fu_fmt")" "$fu_fmt" "$RST")
    fi
  fi
  local mtime now age age_tag=""
  mtime=$(stat -f %m "$cache" 2>/dev/null) || mtime=0
  now=$(date +%s)
  age=$((now - mtime))
  if (( age >= OLD_AFTER_SECONDS )); then
    age_tag=$(printf ' %s[%s old]%s' "$YELLOW" "$(fmt_age "$age")" "$BLUE")
    (( age >= STALE_AFTER_SECONDS )) && age_tag=$(printf ' %s[⚠ %s stale]%s' "$RED" "$(fmt_age "$age")" "$BLUE")
  fi
  printf '%s%s:%s %s%s%%%s%s %s | %s%s  %s' \
    "$BLUE" "$(fmt_name "$email")" "$age_tag" \
    "$sc" "$su_fmt" "$RST" "$BLUE" \
    "$(fmt_reset "$sr_at")" \
    "$weekly_part" "$BLUE" \
    "$(fmt_reset "$wr_at")"
}

# 排第一的是「當前 session 實際在燒的帳號」，不是「default dir 登入誰」。
# lock session（cc -team / cc -max）帶 CLAUDE_CONFIG_DIR 進來，statusline 子 process 繼承得到；
# 一般 session 沒帶 → 退回 user-global，順序與過去一致。
SESSION_EMAIL=""
if [[ -n "${CLAUDE_CONFIG_DIR:-}" && -f "$CLAUDE_CONFIG_DIR/.claude.json" ]]; then
  SESSION_EMAIL=$(jq -r '.oauthAccount.emailAddress // ""' "$CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null)
fi
[[ -z "$SESSION_EMAIL" ]] && SESSION_EMAIL=$(jq -r '.oauthAccount.emailAddress // ""' "$HOME/.claude.json" 2>/dev/null)

email_from_path() {
  local p=$1
  local base=$(basename "$p")
  base=${base#quota-}
  base=${base%.json}
  base=${base%.status}
  printf '%s' "${base//_at_/@}"
}

SIDE_CACHES=()
SIDE_EMAILS=()
SEEN_LIST=""
MAIN_CACHE=""

shopt -s nullglob
for f in "$CACHE_DIR"/quota-*.json "$CACHE_DIR"/quota-*.status; do
  [[ "$f" == *receiver.log ]] && continue
  email=$(email_from_path "$f")
  [[ -z "$email" || "$email" == "unknown" ]] && continue
  case "$EXCLUDE_EMAILS" in
    *"|$email|"*) continue;;
  esac
  case "$SEEN_LIST" in
    *"|$email|"*) continue;;
  esac
  SEEN_LIST="$SEEN_LIST|$email|"
  cache="$CACHE_DIR/quota-${email//@/_at_}.json"
  if [[ "$email" == "$SESSION_EMAIL" ]]; then
    MAIN_CACHE=$cache
  else
    SIDE_CACHES+=("$cache")
    SIDE_EMAILS+=("$email")
  fi
done
shopt -u nullglob

if [[ "${1:-}" == "--visible-accounts-json" ]]; then
  {
    if [[ -n "$MAIN_CACHE" ]]; then
      jq -nc --arg email "$SESSION_EMAIL" --arg cache "$MAIN_CACHE" '{email: $email, cache: $cache}'
    fi
    for i in "${!SIDE_CACHES[@]}"; do
      jq -nc --arg email "${SIDE_EMAILS[$i]}" --arg cache "${SIDE_CACHES[$i]}" '{email: $email, cache: $cache}'
    done
  } | jq -s '{accounts: .}'
  exit 0
fi

if [[ -n "$MAIN_CACHE" ]]; then
  render_segment "$SESSION_EMAIL" "$MAIN_CACHE"
fi

for i in "${!SIDE_CACHES[@]}"; do
  if [[ -n "$MAIN_CACHE" ]] || (( i > 0 )); then
    printf '%s || ' "$BLUE"
  fi
  render_segment "${SIDE_EMAILS[$i]}" "${SIDE_CACHES[$i]}"
done

printf '%s' "$RST"
