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
EXCLUDE_EMAILS="|philip@akohub.com|qwe70301@gmail.com|"

color_for() {
  local v=${1%.*}
  if (( v >= 100 )); then printf '%s' "$RED_BOLD"
  elif (( v >= 80 )); then printf '%s' "$RED"
  elif (( v >= 50 )); then printf '%s' "$YELLOW"
  elif (( v >= 30 )); then printf '%s' "$BLUE"
  else printf '%s' "$GREEN"
  fi
}

color_for_var() {
  if (( ${2%.*} >= 100 )); then printf -v "$1" '%s' "$RED_BOLD"
  elif (( ${2%.*} >= 80 )); then printf -v "$1" '%s' "$RED"
  elif (( ${2%.*} >= 50 )); then printf -v "$1" '%s' "$YELLOW"
  elif (( ${2%.*} >= 30 )); then printf -v "$1" '%s' "$BLUE"
  else printf -v "$1" '%s' "$GREEN"
  fi
}

fmt_name() {
  local prefix="${1%@*}"
  case "$prefix" in
    philiplin)      printf 'Team-P' ;;
    software.agent) printf 'Team-S' ;;
    alex.robin)     printf 'Max' ;;
    *)          printf '%s' "$prefix" ;;
  esac
}

fmt_name_var() {
  case "${2%@*}" in
    philiplin)      printf -v "$1" 'Team-P%s' "${3:-}" ;;
    software.agent) printf -v "$1" 'Team-S%s' "${3:-}" ;;
    alex.robin)     printf -v "$1" 'Max%s' "${3:-}" ;;
    *)              printf -v "$1" '%s%s' "${2%@*}" "${3:-}" ;;
  esac
}

fmt_reset() {
  local at="${1%%.*}"
  [[ -z "$at" ]] && { printf -- '—'; return; }
  local reset_s now_s diff_s
  reset_s=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$at" +%s 2>/dev/null) \
    || { printf -- '—'; return; }
  now_s=${NOW_SEC:-$(date +%s)}
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

fmt_age_var() {
  if (( $2 < 60 )); then printf -v "$1" '%ds' "$2"
  elif (( $2 < 3600 )); then printf -v "$1" '%dm' $(($2 / 60))
  elif (( $2 < 86400 )); then printf -v "$1" '%dh' $(($2 / 3600))
  else printf -v "$1" '%dd' $(($2 / 86400))
  fi
}

render_segment() {
  local email="$1" cache="$2" mark="${3:-}"
  local status="${cache%.json}.status"
  local name
  fmt_name_var name "$email" "$mark"

  # 有 cache 就畫數字，最後一次 fetch 失敗只降級成帳號名旁的 ⚠ 標記。
  # 兩個 writer（chrome extension 30s、poller 180s fallback）任一失敗時，另一個
  # 的資料仍可能是新鮮的；整格藏起來會蓋掉正確數字。cache 的新舊由 age_tag 表達。
  # 完全沒 cache 才退回整格錯誤訊息——那時沒有數字可畫。
  if [[ -f "$status" && ! -f "$cache" ]]; then
    local ts msg
    IFS=$'\t' read -r ts msg < "$status"
    printf '%s%s | %s⚠ %s @ %s%s' "$BLUE" "$name" "$RED" "$msg" "$ts" "$RST"
    return
  fi

  [[ ! -f "$cache" ]] && return
  local q_fields wu wr_at su sr_at fu _q_end
  # 缺欄位畫成 ?：補 0 會讓「沒有資料」看起來像「額度完全沒用」
  # 5 個槽位一律用 // "" 保留位置，避免 jq empty 吞掉中間槽位造成欄位錯位
  q_fields=$(jq -r '[
    (.data.seven_day.utilization // ""),
    (.data.seven_day.resets_at // ""),
    (.data.five_hour.utilization // ""),
    (.data.five_hour.resets_at // ""),
    ([.data.limits[]? | select(.kind == "weekly_scoped") | .percent] | max // ""),
    "END"
  ] | map(tostring) | join("\u001f")' "$cache" 2>/dev/null) || q_fields=""
  IFS=$'\037' read -r wu wr_at su sr_at fu _q_end <<<"$q_fields"
  local wc sc fc wu_fmt su_fmt wu_disp su_disp fu_fmt weekly_part
  if [[ -n "$wu" ]]; then
    color_for_var wc "$wu"; printf -v wu_fmt '%.0f' "$wu"; wu_disp="${wu_fmt}%"
  else
    wc=$YELLOW; wu_fmt=""; wu_disp="?"
  fi
  if [[ -n "$su" ]]; then
    color_for_var sc "$su"; printf -v su_fmt '%.0f' "$su"; su_disp="${su_fmt}%"
  else
    sc=$YELLOW; su_fmt=""; su_disp="?"
  fi
  weekly_part="${wc}${wu_disp}${RST}"
  if [[ -n "$fu" ]]; then
    printf -v fu_fmt '%.0f' "$fu"
    if [[ -z "$wu_fmt" ]] || (( wu_fmt < 100 || fu_fmt < 100 )); then
      color_for_var fc "$fu_fmt"
      weekly_part="${fc}${fu_fmt}%${RST}${BLUE} / ${RST}${weekly_part}"
    fi
  fi
  local mtime now age age_str age_tag=""
  mtime=$(stat -f %m "$cache" 2>/dev/null) || mtime=0
  now=${NOW_SEC:-$(date +%s)}
  age=$((now - mtime))
  if (( age >= OLD_AFTER_SECONDS )); then
    fmt_age_var age_str "$age"
    age_tag=" ${YELLOW}[${age_str} old]${BLUE}"
    (( age >= STALE_AFTER_SECONDS )) && age_tag=" ${RED}[⚠ ${age_str} stale]${BLUE}"
  fi
  local fail_tag=""
  [[ -f "$status" ]] && fail_tag=" ${RED}⚠${BLUE}"
  local sr_disp wr_disp
  sr_disp=$(fmt_reset "$sr_at")
  wr_disp=$(fmt_reset "$wr_at")
  printf '%s%s:%s%s %s%s%s%s %s | %s%s %s' \
    "$BLUE" "$name" "$age_tag" "$fail_tag" \
    "$sc" "$su_disp" "$RST" "$BLUE" \
    "$sr_disp" \
    "$weekly_part" "$BLUE" \
    "$wr_disp"
}

# 排第一的是「當前 session 實際在燒的帳號」，不是「default dir 登入誰」。
#
# 判定順序，強度由高到低：
#   1. OTel map（session-account-receiver.py 收 CC 自報的 session.id -> user.email）
#      ——唯一與程序直接綁定的來源。CC 憑證是 per-process 的：一個 session 跑
#      /login 不會換掉其他正在跑的 session，所以全域檔在多 session 下必然說謊。
#   2. CLAUDE_CONFIG_DIR/.claude.json（lock session：cc -team-p / -team-s 帶進來，
#      statusline 子 process 繼承得到）——帳號綁在啟動指令上，可信。
#   3. $HOME/.claude.json ——只記「最後一次 /login 登了誰」，全域共享。用它時
#      在帳號名後面標 ? 表示未確認，不假裝確定（顧問 2026-09-10 的第 3 條）。
SESSION_EMAIL=""
SESSION_MARK=""
SESSION_MAP="${CC_WIDGET_CACHE_DIR:-/tmp/cc-widget-cache}/session-account.json"
if [[ -n "${CC_SESSION_ID:-}" && -f "$SESSION_MAP" ]]; then
  SESSION_EMAIL=$(jq -r --arg sid "$CC_SESSION_ID" '.sessions[$sid].email // ""' "$SESSION_MAP" 2>/dev/null)
fi
if [[ -z "$SESSION_EMAIL" && -n "${CLAUDE_CONFIG_DIR:-}" && -f "$CLAUDE_CONFIG_DIR/.claude.json" ]]; then
  SESSION_EMAIL=$(jq -r '.oauthAccount.emailAddress // ""' "$CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null)
fi
if [[ -z "$SESSION_EMAIL" ]]; then
  SESSION_EMAIL=$(jq -r '.oauthAccount.emailAddress // ""' "$HOME/.claude.json" 2>/dev/null)
  [[ -n "$SESSION_EMAIL" ]] && SESSION_MARK="?"
fi

email_from_path() {
  local base="${1##*/}"
  base=${base#quota-}
  base=${base%.json}
  base=${base%.status}
  printf '%s' "${base//_at_/@}"
}

email_from_path_var() {
  local _b="${2##*/}"
  _b=${_b#quota-}
  _b=${_b%.json}
  _b=${_b%.status}
  printf -v "$1" '%s' "${_b//_at_/@}"
}

SIDE_CACHES=()
SIDE_EMAILS=()
SEEN_LIST=""
MAIN_CACHE=""

shopt -s nullglob
for f in "$CACHE_DIR"/quota-*.json "$CACHE_DIR"/quota-*.status; do
  [[ "$f" == *receiver.log ]] && continue
  email_from_path_var email "$f"
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

NOW_SEC=$(date +%s)

if [[ -n "$MAIN_CACHE" ]]; then
  render_segment "$SESSION_EMAIL" "$MAIN_CACHE" "$SESSION_MARK"
fi

for i in "${!SIDE_CACHES[@]}"; do
  if [[ -n "$MAIN_CACHE" ]] || (( i > 0 )); then
    printf '%s || ' "$BLUE"
  fi
  render_segment "${SIDE_EMAILS[$i]}" "${SIDE_CACHES[$i]}"
done

printf '%s' "$RST"
