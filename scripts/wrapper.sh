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
RED_BOLD=$'\033[1;38;5;160m'
GRAY=$'\033[38;5;243m'
PURPLE=$'\033[38;5;141m'
RST=$'\033[0m'
BOLD=$'\033[1m'
NORM=$'\033[22m'

# ----- pill rendering layer (visual design adapted from Nanako0129/coralline,
#       which is itself a tribute to romkatv/powerlevel10k) -----
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

WT_STYLE="pill"          # pill: powerline pills | lean: flat accent text
WT_THEME="claude-coral"  # any file in themes/<name>.conf
WT_LAYOUT="fixed"        # fixed: 3 semantic lines | auto: greedy wrap stream
WT_MAX_LINES=3           # auto only
WT_BAR_WIDTH=10
WT_BAR_FILL="▰"
WT_BAR_EMPTY="▱"

WT_CONF="${CC_WIDGETS_CONF:-$HOME/.claude/cc-widgets-theme.conf}"
[[ -f "$WT_CONF" ]] && . "$WT_CONF"

for _td in "$SCRIPT_DIR/themes" "$SCRIPT_DIR/../themes"; do
  if [[ -f "$_td/$WT_THEME.conf" ]]; then . "$_td/$WT_THEME.conf"; break; fi
done

VL_FG_TEXT=${VL_FG_TEXT:-231}
VL_FG_DIM=${VL_FG_DIM:-245}
VL_FG_OK=${VL_FG_OK:-114}
VL_FG_WARN=${VL_FG_WARN:-179}
VL_FG_HOT=${VL_FG_HOT:-167}

# map coralline theme palette onto this wrapper's widget set
WT_BG_MODEL=${WT_BG_MODEL:-${VL_BG_MODEL:-173}}
WT_BG_CACHE=${WT_BG_CACHE:-${VL_BG_5H:-237}}
WT_BG_SKILL=${WT_BG_SKILL:-${VL_BG_STYLE:-96}}
WT_BG_GIT_OK=${WT_BG_GIT_OK:-${VL_BG_GIT_OK:-65}}
WT_BG_GIT_DIRTY=${WT_BG_GIT_DIRTY:-${VL_BG_GIT_DIRTY:-130}}
WT_BG_COST=${WT_BG_COST:-${VL_BG_COST:-212,125,145}}
WT_BG_RUNAWAY=${WT_BG_RUNAWAY:-${VL_FG_HOT:-167}}
WT_BG_USAGE=${WT_BG_USAGE:-${VL_BG_7D:-236}}
WT_BG_USAGE2=${WT_BG_USAGE2:-${VL_BG_CTX:-238}}
WT_BG_VENDOR=${WT_BG_VENDOR:-${VL_BG_CLOCK:-70,80,110}}
WT_BG_GLM=${WT_BG_GLM:-${VL_BG_GLM:-99}}
WT_BG_CTX=${WT_BG_CTX:-${VL_BG_CTX:-238}}
WT_BG_SYS=${WT_BG_SYS:-${VL_BG_LINES:-240}}
WT_BG_SYS2=${WT_BG_SYS2:-${VL_BG_DURATION:-60}}

CAP_L=$(printf '\xee\x82\xb6')   # U+E0B6 left rounded cap
CAP_R=$(printf '\xee\x82\xb4')   # U+E0B4 right rounded cap
SEP=$(printf '\xee\x82\xb0')     # U+E0B0 powerline separator

bg() {
  [[ -n "$1" ]] || return 0
  if [[ "${1#*,}" != "$1" ]]; then
    local IFS=','; set -- $1; printf '\033[48;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf '\033[48;5;%sm' "$1"; fi
}
fg() {
  [[ -n "$1" ]] || return 0
  if [[ "${1#*,}" != "$1" ]]; then
    local IFS=','; set -- $1; printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf '\033[38;5;%sm' "$1"; fi
}

pct_color() {
  local p=${1:-0}
  if   (( p >= 75 )); then printf '%s' "$VL_FG_HOT"
  elif (( p >= 50 )); then printf '%s' "$VL_FG_WARN"
  else                     printf '%s' "$VL_FG_OK"; fi
}

quota_pct_color() {
  local p=${1%.*}
  : ${p:=0}
  if   (( p >= 100 )); then printf '%s' "$RED_BOLD"
  elif (( p >= 80 ));  then printf '%s' "$RED"
  elif (( p >= 50 ));  then printf '%s' "$YELLOW"
  elif (( p >= 30 ));  then printf '%s' "$BLUE"
  else                      printf '%s' "$GREEN"
  fi
}

fmt_glm_countdown() {
  local reset_ms=$1
  if [[ -z "$reset_ms" || "$reset_ms" == "null" || "$reset_ms" == "0" ]]; then
    printf '0m'
    return
  fi
  local reset_s=$(( reset_ms / 1000 ))
  local diff_s=$(( reset_s - $(date +%s) ))
  if (( diff_s <= 0 )); then printf '0m'; return; fi
  local d=$(( diff_s / 86400 )) h=$(( (diff_s % 86400) / 3600 )) m=$(( (diff_s % 3600) / 60 ))
  if (( d > 0 )); then printf '%dd%dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh%dm' "$h" "$m"
  else printf '%dm' "$m"
  fi
}

GLM_5H_PCT="" ; GLM_W_PCT="" ; GLM_LEVEL=""
S1_BG=() ; S1_TX=() ; S2_BG=() ; S2_TX=() ; S3_BG=() ; S3_TX=()
push_seg() {  # $1=line-no $2=bg $3=text
  eval "S${1}_BG[\${#S${1}_BG[@]}]=\$2 ; S${1}_TX[\${#S${1}_TX[@]}]=\$3"
}

render_range() {  # render RB/RT[$1..$2] as one row → stdout
  local s=$1 e=$2 i out t b rebg
  if [[ "$WT_STYLE" == "lean" ]]; then
    out=""
    for ((i=s; i<=e; i++)); do
      out+="${RST}$(fg "${RB[i]}")${RT[i]}"
      (( i < e )) && out+="${RST}  "
    done
    printf '%s' "${out}${RST}"
    return 0
  fi
  out="${RST}$(fg "${RB[s]}")${CAP_L}"
  for ((i=s; i<=e; i++)); do
    b=${RB[i]} ; t=${RT[i]}
    rebg="${RST}$(bg "$b")$(fg "$VL_FG_TEXT")"
    t=${t//"$RST"/$rebg}
    out+="$(bg "$b")$(fg "$VL_FG_TEXT") ${t} "
    (( i < e )) && out+="${RST}$(bg "${RB[i+1]}")$(fg "$b")${SEP}"
  done
  printf '%s' "${out}${RST}$(fg "${RB[e]}")${CAP_R}${RST}"
}

render_line() {  # $1=line-no → stdout (empty if no segments)
  eval "RB=( \${S${1}_BG[@]+\"\${S${1}_BG[@]}\"} ) ; RT=( \${S${1}_TX[@]+\"\${S${1}_TX[@]}\"} )"
  local n=${#RB[@]}
  (( n == 0 )) && return 0
  render_range 0 $((n-1))
}

seg_widths() {  # NUL-separated texts on stdin → one visible width per line
  perl -CSDA -0 -ne '
    sub cw {
      my $o = shift;
      return 0 if $o == 0x200D
                || ($o >= 0x0300 && $o <= 0x036F)
                || ($o >= 0x200B && $o <= 0x200F)
                || ($o >= 0xFE00 && $o <= 0xFE0F)
                || ($o >= 0x1F3FB && $o <= 0x1F3FF);
      return 2 if ($o >= 0x1100 && $o <= 0x115F)
                || ($o >= 0x2E80 && $o <= 0x303E)
                || ($o >= 0x3041 && $o <= 0x33FF)
                || ($o >= 0x3400 && $o <= 0x4DBF)
                || ($o >= 0x4E00 && $o <= 0x9FFF)
                || ($o >= 0xA000 && $o <= 0xA4CF)
                || ($o >= 0xAC00 && $o <= 0xD7A3)
                || ($o >= 0xF900 && $o <= 0xFAFF)
                || ($o >= 0xFE30 && $o <= 0xFE4F)
                || ($o >= 0xFF00 && $o <= 0xFF60)
                || ($o >= 0xFFE0 && $o <= 0xFFE6)
                || ($o >= 0x1F300 && $o <= 0x1F9FF)
                || ($o >= 0x20000 && $o <= 0x2FFFD)
                || ($o >= 0x30000 && $o <= 0x3FFFD);
      return 1;
    }
    chomp;
    s/\e\[[0-9;]*[a-zA-Z]//g;
    my $w = 0;
    $w += cw(ord($_)) for split //;
    print "$w\n";
  '
}
# ----- end pill rendering layer -----

input=$(cat)
jqr() { jq -r "$1" <<<"$input" 2>/dev/null; }

probe_cols() {
  [[ -n "${WT_FORCE_COLS:-}" ]] && { printf '%s' "$WT_FORCE_COLS"; return; }
  local pid=$$
  local i
  for i in 1 2 3 4 5 6 7 8; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$pid" || "$pid" == "0" ]] && break
    local tty
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$tty" || "$tty" == "??" || "$tty" == "?" ]] && continue
    local size
    size=$(stty size < "/dev/$tty" 2>/dev/null | awk '{print $2}')
    [[ -n "$size" && "$size" -gt 0 ]] && { printf '%s' "$size"; return; }
  done
  tput cols 2>/dev/null || true
}

fit_to_cols() {
  # Pass through if visual width <= max, else truncate with ellipsis.
  # ANSI escapes count as zero-width. Per-codepoint width:
  #   0 — combining marks, ZWJ, variation selectors, skin-tone modifiers
  #   2 — Hangul Jamo, CJK, fullwidth, emoji
  #   1 — everything else (incl. block elements U+2580–259F)
  perl -CSDA -e '
    sub cw {
      my $o = shift;
      return 0 if $o == 0x200D
                || ($o >= 0x0300 && $o <= 0x036F)
                || ($o >= 0x200B && $o <= 0x200F)
                || ($o >= 0xFE00 && $o <= 0xFE0F)
                || ($o >= 0x1F3FB && $o <= 0x1F3FF);
      return 2 if ($o >= 0x1100 && $o <= 0x115F)
                || ($o >= 0x2E80 && $o <= 0x303E)
                || ($o >= 0x3041 && $o <= 0x33FF)
                || ($o >= 0x3400 && $o <= 0x4DBF)
                || ($o >= 0x4E00 && $o <= 0x9FFF)
                || ($o >= 0xA000 && $o <= 0xA4CF)
                || ($o >= 0xAC00 && $o <= 0xD7A3)
                || ($o >= 0xF900 && $o <= 0xFAFF)
                || ($o >= 0xFE30 && $o <= 0xFE4F)
                || ($o >= 0xFF00 && $o <= 0xFF60)
                || ($o >= 0xFFE0 && $o <= 0xFFE6)
                || ($o >= 0x1F300 && $o <= 0x1F9FF)
                || ($o >= 0x20000 && $o <= 0x2FFFD)
                || ($o >= 0x30000 && $o <= 0x3FFFD);
      return 1;
    }
    my ($max, $text) = @ARGV;
    my $stripped = $text;
    $stripped =~ s/\e\[[0-9;]*[a-zA-Z]//g;
    my $w = 0;
    for my $c (split //, $stripped) {
      $w += cw(ord($c));
    }
    if ($w <= $max) { print $text; exit; }
    my $vis = 0;
    my $out = "";
    while ($text =~ /\G(\e\[[0-9;]*[a-zA-Z]|.)/gs) {
      my $tok = $1;
      if ($tok =~ /^\e/) { $out .= $tok; next; }
      my $tw = cw(ord($tok));
      last if $vis + $tw > $max - 1;
      $out .= $tok;
      $vis += $tw;
    }
    $out .= "\x{2026}\e[0m";
    print $out;
  ' -- "$1" "$2"
}

# Conditional widgets (read early so they can prefix line1 — most visible spot)
runaway=$(cat "$CACHE_DIR/runaway.txt" 2>/dev/null || printf '')

# ----- Line 1 -----
model_name=$(jqr '.model.display_name // (if (.model | type) == "string" then .model else "?" end)')

# cache health: last-turn hit% + session flush count + bug-induced waste
# Algorithm and waste formula adapted from https://github.com/AlexZan/cc-cache-monitor
cache_hit_fmt=""
transcript_path=$(jqr '.transcript_path // ""')
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
  cache_data=$(jq -s '
    [.[] | select(.message.usage and .timestamp)] as $all
    | [$all[] | .message.usage] as $usages
    | [$all[]
        | .message.usage as $u
        | ($u.cache_read_input_tokens // 0) as $cr
        | ($u.cache_creation_input_tokens // 0) as $cw
        | ($u.input_tokens // 0) as $it
        | ($cr + $cw + $it) as $tot
        | select($tot > 0 and ($cr * 100 / $tot) >= 50)
        | $cw] as $healthy
    | (if ($healthy | length) > 0 then $healthy | min else 0 end) as $base
    | ($usages | last) as $last
    | (reduce ($all | sort_by(.timestamp))[] as $m (
        {w: 0, p: null};
        $m.message.usage as $u
        | ($u.cache_read_input_tokens // 0) as $cr
        | ($u.cache_creation_input_tokens // 0) as $cw
        | ($u.input_tokens // 0) as $it
        | ($cr + $cw + $it) as $tot
        | ($m.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $ts
        | (if .p == null then 999999 else ($ts - .p) end) as $gap
        | if $tot > 0 and ($cr * 100 / $tot) < 50 and $gap < 3600 and $cw > $base
          then {w: (.w + (($cw - $base) * 115 / 100 | floor)), p: $ts}
          else . + {p: $ts} end
      ) | .w) as $session_waste
    | if $last == null then null else
        ($last.cache_read_input_tokens // 0) as $cr
        | ($last.cache_creation_input_tokens // 0) as $cw
        | ($last.input_tokens // 0) as $it
        | ($cr + $cw + $it) as $tot
        | (($all | sort_by(.timestamp) | last).timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $last_ts
        | {
            hit: (if $tot > 0 then ($cr * 100 / $tot | floor) else -1 end),
            flushes: ([$usages[1:][]
              | (.cache_read_input_tokens // 0) as $r
              | (.cache_creation_input_tokens // 0) as $w
              | (.input_tokens // 0) as $i
              | ($r + $w + $i) as $t
              | select($t > 0 and ($r * 100 / $t) < 50)] | length),
            session_waste: $session_waste,
            last_ts: $last_ts
          }
      end
  ' "$transcript_path" 2>/dev/null)
  if [[ -n "$cache_data" && "$cache_data" != "null" ]]; then
    hit=$(jq -r '.hit' <<<"$cache_data")
    flushes=$(jq -r '.flushes' <<<"$cache_data")
    waste=$(jq -r '.session_waste // 0' <<<"$cache_data")

    if [[ "$hit" == "-1" ]]; then
      cache_hit_fmt="${GRAY}Cache: --${RST}"
    else
      if   (( hit < 50 )); then hit_color="$RED";    warn="⚠"
      elif (( hit < 90 )); then hit_color="$YELLOW"; warn=""
      else                       hit_color="$GREEN"; warn=""
      fi
      cache_hit_fmt="${GRAY}Cache: ${RST}${hit_color}${warn}${hit}%${RST}"

      idle_ts=$(jq -r '.last_ts // empty' <<<"$cache_data")
      if [[ -n "$idle_ts" ]]; then
        idle=$(( $(date +%s) - idle_ts ))
        (( idle < 0 )) && idle=0
        idle_min=$(( idle / 60 ))
        if (( idle < 3600 )); then idle_fmt="${idle_min}m"
        else idle_fmt="$(( idle / 3600 ))h$(( (idle % 3600) / 60 ))m"
        fi
        if   (( idle_min >= 50 )); then idle_color="$RED";    idle_warn="⚠ "
        elif (( idle_min >= 30 )); then idle_color="$YELLOW"; idle_warn=""
        else                            idle_color="$GREEN";  idle_warn=""
        fi
        cache_hit_fmt="${cache_hit_fmt} ${idle_color}${idle_warn}${idle_fmt}${RST}"
      fi
    fi
  fi
fi

session_cost_usd=$(jqr '.cost.total_cost_usd // 0')
session_cost_fmt=$(awk -v c="$session_cost_usd" 'BEGIN { printf "$%.2f", c }')

cwd=$(jqr '.workspace.current_dir // .cwd // ""')

git_branch_fmt="⎇ no git"
git_ab_fmt="(no git)"
git_dirty=0
if [[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "?")
  git_marks=$(git status --porcelain 2>/dev/null | awk '
    /^\?\?/ { u=1; next }
    { if (substr($0,1,1) != " ") s=1; if (substr($0,2,1) != " ") m=1 }
    END { printf "%s%s%s", (s?"+":""), (m?"!":""), (u?"?":"") }')
  [[ -n "$git_marks" ]] && git_dirty=1
  git_branch_fmt="⎇ ${branch}${git_marks}"
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [[ -n "$upstream" ]]; then
    ahead=$(git rev-list --count "$upstream"..HEAD 2>/dev/null || echo 0)
    behind=$(git rev-list --count HEAD.."$upstream" 2>/dev/null || echo 0)
    git_ab_fmt=""
    (( ahead > 0 ))  && git_ab_fmt="⇡${ahead}"
    (( behind > 0 )) && git_ab_fmt="${git_ab_fmt}⇣${behind}"
  else
    git_ab_fmt="(no upstream)"
  fi
fi

session_id=$(jqr '.session_id // ""')
skill_name=""
if [[ -n "$session_id" ]]; then
  skill_name=$(cat "$CACHE_DIR/skill-${session_id}.txt" 2>/dev/null)
fi
if [[ -n "$skill_name" ]]; then
  skills_fmt="🪄 $skill_name"
else
  skills_fmt="🪄 -"
fi

[[ -n "$runaway" ]] && push_seg 1 "$WT_BG_RUNAWAY" "$runaway"
push_seg 1 "$WT_BG_MODEL" "${BOLD}◆ ${model_name}${NORM}"
[[ -n "$cache_hit_fmt" ]] && push_seg 1 "$WT_BG_CACHE" "$cache_hit_fmt"
push_seg 1 "$WT_BG_SKILL" "$skills_fmt"
git_seg="$git_branch_fmt"
[[ -n "$git_ab_fmt" ]] && git_seg="${git_seg} ${git_ab_fmt}"
git_bg="$WT_BG_GIT_OK"
(( git_dirty )) && git_bg="$WT_BG_GIT_DIRTY"
push_seg 1 "$git_bg" "${BOLD}${git_seg}${NORM}"
push_seg 1 "$WT_BG_COST" "$session_cost_fmt"

# ----- Line 2: Anthropic quota + vendor balances -----
QUOTA_CACHE_DIR="$HOME/.claude/cache"
ACTIVE_PID=$(tr -d '[:space:]' < "$QUOTA_CACHE_DIR/vendor-active-profile" 2>/dev/null || echo "")
[[ "$ACTIVE_PID" =~ ^[0-9a-f]{8}$ ]] || ACTIVE_PID=""

fmt_vendor_balance() {
  local vendor=$1 label=$2 red_thresh=$3 yellow_thresh=$4
  local pid="$ACTIVE_PID"
  if [[ -z "$pid" ]]; then
    local first_json
    first_json=$(ls "$QUOTA_CACHE_DIR/vendor-${vendor}"-[0-9a-f]*.json 2>/dev/null | head -1)
    [[ -n "$first_json" ]] && pid=$(basename "$first_json" .json | sed "s/^vendor-${vendor}-//")
  fi
  [[ -z "$pid" ]] && return
  local json="$QUOTA_CACHE_DIR/vendor-${vendor}-${pid}.json"
  local status="$QUOTA_CACHE_DIR/vendor-${vendor}-${pid}.status"

  if [[ -f "$status" ]]; then
    local reason
    reason=$(head -1 "$status" 2>/dev/null | cut -f2)
    if [[ -n "$label" ]]; then
      printf '%s%s: %s%s' "$RED" "$label" "${reason:-err}" "$RST"
    else
      printf '%s%s%s' "$RED" "${reason:-err}" "$RST"
    fi
    return
  fi

  [[ ! -f "$json" ]] && return

  local balance currency
  balance=$(jq -r '.data.balance // ""' "$json" 2>/dev/null)
  currency=$(jq -r '.data.currency // "USD"' "$json" 2>/dev/null)
  [[ -z "$balance" || "$balance" == "null" ]] && return

  local color
  color=$(awk -v b="$balance" -v r="$red_thresh" -v y="$yellow_thresh" '
  BEGIN {
    if (b == "" || b == "0" || b == "0.00")  print "R"
    else if (b + 0 < r) print "R"
    else if (b + 0 < y) print "Y"
    else                 print "G"
  }')

  local c sym="\$"
  [[ "$currency" == "CNY" ]] && sym="¥"
  case "$color" in
    R) c="$RED" ;;
    Y) c="$YELLOW" ;;
    *) c="$GREEN" ;;
  esac

  local sep=""
  [[ -n "$label" ]] && sep="${BLUE}${label}: ${RST}"
  printf '%s%s%s%s%s' "$sep" "$c" "$sym" "$balance" "$RST"
}

fmt_deepseek_balances() {
  local label=$1
  local result="" first=1
  for json in "$QUOTA_CACHE_DIR/vendor-deepseek"-[0-9a-f]*.json; do
    [[ ! -f "$json" ]] && continue
    [[ "$json" == *-plan-* ]] && continue
    local base="${json%.json}"
    [[ -f "${base}.status" ]] && continue

    while IFS=$'\t' read -r currency balance; do
      [[ -z "$balance" || "$balance" == "null" || "$balance" == "0" || "$balance" == "0.00" ]] && continue

      local red yellow
      if [[ "$currency" == "CNY" ]]; then
        red=8; yellow=30
      else
        red=1; yellow=4
      fi

      local color
      color=$(awk -v b="$balance" -v r="$red" -v y="$yellow" '
      BEGIN {
        if (b + 0 < r) print "R"
        else if (b + 0 < y) print "Y"
        else                 print "G"
      }')

      local c sym="\$"
      [[ "$currency" == "CNY" ]] && sym="¥"
      case "$color" in
        R) c="$RED" ;;
        Y) c="$YELLOW" ;;
        *) c="$GREEN" ;;
      esac

      local sep=""
      [[ $first -eq 0 ]] && sep="${BLUE} | ${RST}"
      local lbl=""
      [[ $first -eq 1 && -n "$label" ]] && lbl="${BLUE}${label}: ${RST}"
      result="${result}${sep}${lbl}${c}${sym}${balance}${RST}"
      first=0
    done < <(jq -r '.data.balance_infos // [] | sort_by(.currency) | .[] | "\(.currency)\t\(.total_balance)"' "$json" 2>/dev/null)
  done
  [[ -n "$result" ]] && printf '%s' "$result"
}

fmt_vendor_plan() {
  local vendor=$1
  local pid="$ACTIVE_PID"
  if [[ -z "$pid" ]]; then
    local first_json
    first_json=$(ls "$QUOTA_CACHE_DIR/vendor-${vendor}"-[0-9a-f]*.json 2>/dev/null | head -1)
    [[ -n "$first_json" ]] && pid=$(basename "$first_json" .json | sed "s/^vendor-${vendor}-//")
  fi
  [[ -z "$pid" ]] && return
  local json="$QUOTA_CACHE_DIR/vendor-${vendor}-plan-${pid}.json"
  [[ ! -f "$json" ]] && return

  local pct
  pct=$(jq -r '.data.month_percent // 0' "$json" 2>/dev/null)
  [[ -z "$pct" || "$pct" == "null" ]] && return

  local pct_fmt
  pct_fmt=$(awk -v p="$pct" 'BEGIN { printf "%.1f", p * 100 }')

  local color
  color=$(awk -v p="$pct" '
  BEGIN {
    if (p + 0 >= 0.8) print "R"
    else if (p + 0 >= 0.5) print "Y"
    else                    print "G"
  }')

  local c
  case "$color" in
    R) c="$RED" ;;
    Y) c="$YELLOW" ;;
    *) c="$GREEN" ;;
  esac

  printf '%s%s%%%s' "$c" "$pct_fmt" "$RST"
}
fmt_glm_quota() {
  local pid="$ACTIVE_PID"
  if [[ -z "$pid" ]]; then
    local first_json
    first_json=$(ls "$QUOTA_CACHE_DIR/vendor-glm"-[0-9a-f]*.json 2>/dev/null | head -1)
    [[ -n "$first_json" ]] && pid=$(basename "$first_json" .json | sed 's/^vendor-glm-//')
  fi
  [[ -z "$pid" ]] && return
  local json="$QUOTA_CACHE_DIR/vendor-glm-${pid}.json"
  local status="$QUOTA_CACHE_DIR/vendor-glm-${pid}.status"

  if [[ -f "$status" ]]; then
    local reason
    reason=$(head -1 "$status" 2>/dev/null | cut -f2)
    printf '%sGLM: %s%s' "$RED" "${reason:-err}" "$RST"
    return
  fi

  [[ ! -f "$json" ]] && return

  local parsed
  parsed=$(jq -r '
    .data as $d
    | ($d.level // "glm") as $level
    | ($d.limits // []) as $L
    | (now * 1000) as $now_ms
    | (
        ([$L[] | select(.type=="TOKENS_LIMIT" and .unit==3 and .number==5)] | first)
        // ([$L[] | select(.type=="TOKENS_LIMIT" and (.nextResetTime // null) == null)] | first)
      ) as $h5
    | (
        ([$L[] | select(.type=="TOKENS_LIMIT" and .unit==6 and .number==1)] | first)
        // ([$L[] | select(
              .type=="TOKENS_LIMIT" and (.nextResetTime // 0) > 0
              and ((.nextResetTime - $now_ms) > (5*86400000))
              and ((.nextResetTime - $now_ms) < (9*86400000))
           )] | first)
      ) as $wk
    | [
        ($h5.percentage // ""),
        ($wk.percentage // ""),
        ($wk.nextResetTime // ""),
        $level
      ] | @tsv
  ' "$json" 2>/dev/null)

  local fivehr_pct weekly_pct weekly_reset level
  IFS=$'	' read -r fivehr_pct weekly_pct weekly_reset level <<<"$parsed"

  [[ -z "$fivehr_pct" && -z "$weekly_pct" ]] && return

  GLM_5H_PCT="$fivehr_pct"
  GLM_W_PCT="$weekly_pct"
  GLM_LEVEL="$level"

  local label
  label="$(printf '%s' "$level" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"

  local out="${BLUE}${label}: ${RST}"

  if [[ -n "$fivehr_pct" ]]; then
    local p1_int p1_color cd1
    p1_int=$(awk -v p="$fivehr_pct" 'BEGIN { printf "%d", p }')
    p1_color=$(quota_pct_color "$p1_int")
    cd1=$(fmt_glm_countdown "")
    out="${out}${p1_color}${p1_int}%${RST}${BLUE} ${cd1}${RST}"
  fi

  if [[ -n "$weekly_pct" ]]; then
    local p2_int p2_color cd2
    p2_int=$(awk -v p="$weekly_pct" 'BEGIN { printf "%d", p }')
    p2_color=$(quota_pct_color "$p2_int")
    cd2=$(fmt_glm_countdown "$weekly_reset")
    [[ -n "$fivehr_pct" ]] && out="${out}${BLUE} | ${RST}"
    out="${out}${p2_color}${p2_int}%${RST}${BLUE} ${cd2}${RST}"
  fi

  printf '%s' "$out"
}

usage_part=""
if [[ -x "$HOME/.claude/scripts/usage-color.sh" ]]; then
  usage_part=$("$HOME/.claude/scripts/usage-color.sh" 2>/dev/null || echo "")
fi
trim_ws() {
  local s="$1"
  s="${s#"${s%%[! ]*}"}"
  s="${s%"${s##*[! ]}"}"
  printf '%s' "$s"
}
if [[ -n "$usage_part" ]]; then
  # usage-color.sh joins accounts with "||" — split into one pill per account
  usage_rest="$usage_part"
  usage_i=0
  while :; do
    if [[ "$usage_rest" == *"||"* ]]; then
      usage_chunk="${usage_rest%%||*}"
      usage_rest="${usage_rest#*||}"
    else
      usage_chunk="$usage_rest"
      usage_rest=""
    fi
    usage_chunk=$(trim_ws "$usage_chunk")
    if [[ -n "$usage_chunk" ]]; then
      if (( usage_i % 2 == 0 )); then
        push_seg 2 "$WT_BG_USAGE" "$usage_chunk"
      else
        push_seg 2 "$WT_BG_USAGE2" "$usage_chunk"
      fi
      usage_i=$((usage_i+1))
    fi
    [[ -z "$usage_rest" ]] && break
  done
fi

_glm_tmp=$(mktemp)
fmt_glm_quota >"$_glm_tmp" 2>/dev/null
glm_part=$(cat "$_glm_tmp"); rm -f "$_glm_tmp"
[[ -n "$glm_part" ]] && push_seg 2 "$WT_BG_GLM" "$glm_part"

ds_part=$(fmt_deepseek_balances "DS" 2>/dev/null || echo "")
[[ -n "$ds_part" ]] && push_seg 2 "$WT_BG_VENDOR" "$ds_part"

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

bar_width=$WT_BAR_WIDTH
bar_filled=$(( (ctx_used_int * bar_width + 50) / 100 ))
(( bar_filled > bar_width )) && bar_filled=$bar_width
(( bar_filled < 0 )) && bar_filled=0
bar=""
i=0
while (( i < bar_width )); do
  if (( i < bar_filled )); then bar="${bar}${WT_BAR_FILL}"
  else bar="${bar}${WT_BAR_EMPTY}"
  fi
  i=$(( i + 1 ))
done
ctx_bar_fmt="⛁ [${bar}] ${ctx_used_k}k/${ctx_total_k}k (${ctx_used_int}%)"
ctx_seg="$(fg "$(pct_color "$ctx_used_int")")⛁ ${bar} ${ctx_used_int}%${RST}$(fg "$VL_FG_DIM") ${ctx_used_k}k/${ctx_total_k}k${RST}"

# read daemon-written widgets
cpu=$(cat "$CACHE_DIR/cpu.txt" 2>/dev/null || printf 'CPU: ?')
thermals=$(cat "$CACHE_DIR/thermals.txt" 2>/dev/null || printf '🌡️ ?')
free_mem=$(cat "$CACHE_DIR/memory.txt" 2>/dev/null || printf 'Mem: ?')
disk=$(cat "$CACHE_DIR/disk.txt" 2>/dev/null || printf '💾 ?')
battery=$(cat "$CACHE_DIR/battery.txt" 2>/dev/null || printf '🔋?')

push_seg 3 "$WT_BG_CTX"  "$ctx_seg"
push_seg 3 "$WT_BG_SYS"  "$cpu"
push_seg 3 "$WT_BG_SYS2" "$thermals"
push_seg 3 "$WT_BG_SYS"  "$free_mem"
push_seg 3 "$WT_BG_SYS2" "$disk"
push_seg 3 "$WT_BG_SYS"  "$battery"

# ----- Render segments and fit to terminal width -----
line1=$(render_line 1)
line2=$(render_line 2)
line3=$(render_line 3)
line1_full="$line1"
line2_full="$line2"
line3_full="$line3"

cols=$(probe_cols)
effective_cols=20
if [[ -n "$cols" && "$cols" -gt 0 ]]; then
  effective_cols=$(( cols - 6 ))
  (( effective_cols < 20 )) && effective_cols=20
fi

if [[ "$WT_LAYOUT" == "auto" ]]; then
  # merge all segments into one stream, greedy-wrap by visible width
  RB=( ${S1_BG[@]+"${S1_BG[@]}"} ${S2_BG[@]+"${S2_BG[@]}"} ${S3_BG[@]+"${S3_BG[@]}"} )
  RT=( ${S1_TX[@]+"${S1_TX[@]}"} ${S2_TX[@]+"${S2_TX[@]}"} ${S3_TX[@]+"${S3_TX[@]}"} )
  total=${#RB[@]}
  if (( total > 0 )); then
    SEG_W=()
    while IFS= read -r w; do
      SEG_W[${#SEG_W[@]}]=$w
    done < <(for t in "${RT[@]}"; do printf '%s\0' "$t"; done | seg_widths)
    if [[ "$WT_STYLE" == "lean" ]]; then cap_w=0; sep_w=2; pad_w=0
    else                                 cap_w=2; sep_w=1; pad_w=2; fi
    start=0 ; nlines=1 ; cur=$(( cap_w + SEG_W[0] + pad_w ))
    out_rows=""
    for ((i=1; i<total; i++)); do
      need=$(( cur + sep_w + SEG_W[i] + pad_w ))
      if (( need > effective_cols && nlines < WT_MAX_LINES )); then
        out_rows="${out_rows}$(render_range "$start" $((i-1)))"$'\n'
        start=$i ; nlines=$((nlines+1)) ; cur=$(( cap_w + SEG_W[i] + pad_w ))
      else
        cur=$need
      fi
    done
    out_rows="${out_rows}$(render_range "$start" $((total-1)))"
    printf '%s\n' "$out_rows"
  fi
else
  line1=$(fit_to_cols "$effective_cols" "$line1")
  [[ -n "$line2" ]] && line2=$(fit_to_cols "$effective_cols" "$line2")
  line3=$(fit_to_cols "$effective_cols" "$line3")
  if [[ -n "$line2" ]]; then
    printf '%s\n%s\n%s\n' "$line1" "$line2" "$line3"
  else
    printf '%s\n%s\n' "$line1" "$line3"
  fi
fi

# preview mode: skip side effects (i18n bridge + widget-log)
[[ -n "${WT_NO_LOG:-}" ]] && exit 0

# ----- cc-i18n-proxy web statusline bridge (active when uuid file present) -----
intl_uuid=""
if [[ -n "$cwd" ]]; then
  bridge_key="${CMUX_SURFACE_ID:-}"
  if [[ -z "$bridge_key" && -n "$session_id" ]]; then
    bridge_key="$session_id"
  fi
  if [[ -z "$bridge_key" ]]; then
    bridge_key=$(printf '%s' "$cwd" | shasum -a 256 | cut -c1-12)
  fi
  uuid_file="$HOME/.cc-i18n-proxy/intl-uuid-by-key/$bridge_key.uuid"
  if [[ -f "$uuid_file" ]]; then
    intl_uuid=$(tr -d '[:space:]' < "$uuid_file")
  fi
fi
if [[ -n "$intl_uuid" ]] && [[ "$intl_uuid" =~ ^[a-fA-F0-9]{1,64}$ ]]; then
  out_dir="$CACHE_DIR/by-intl-uuid"
  mkdir -p "$out_dir"
  tmp_file="$out_dir/$intl_uuid.json.tmp.$$"
  final_file="$out_dir/$intl_uuid.json"
  jq --arg l1 "$line1_full" --arg l2 "$line2_full" --arg l3 "$line3_full" \
     '. + {"_lines": [$l1, $l2, $l3]}' \
     <<<"$input" > "$tmp_file" 2>/dev/null \
     && mv "$tmp_file" "$final_file" \
     || rm -f "$tmp_file"
fi
# ----- end bridge -----

# ----- widget-log: 5min throttle, append-only jsonl snapshot -----
# Records all statusline widget values for future analysis. Lives inside
# ~/.claude/projects/ git repo (= claude-session-backups), auto-backed-up
# daily by session-backup launchd job. Append-only policy applies.
#
# METHODOLOGY: statusline is the curation source of truth — when adding,
# removing, or renaming widgets above, update this hook's schema in
# lockstep. The log should always mirror what's currently on screen.
WIDGET_LOG_DIR="$HOME/.claude/projects/widget-log"
WIDGET_LOG_LAST="$CACHE_DIR/.widget-log-last-ts"
NOW_SEC=$(date +%s)
LAST_SEC=$(cat "$WIDGET_LOG_LAST" 2>/dev/null || echo 0)
if (( NOW_SEC - LAST_SEC >= 300 )); then
  printf '%s' "$NOW_SEC" > "$WIDGET_LOG_LAST"
  mkdir -p "$WIDGET_LOG_DIR" 2>/dev/null
  jq -nc \
    --arg ts          "$(date -u +%FT%TZ)" \
    --arg cwd         "$cwd" \
    --arg session_id  "$session_id" \
    --arg model       "$model_name" \
    --arg cost        "$session_cost_usd" \
    --arg cache_hit   "${hit:-}" \
    --arg cache_flushes "${flushes:-0}" \
    --arg cache_waste "${waste:-0}" \
    --arg cache_idle  "${idle:-}" \
    --arg ctx_pct     "$ctx_used_pct" \
    --arg ctx_tokens  "$ctx_used_tokens" \
    --arg skill       "$skill_name" \
    --arg glm_level   "${GLM_LEVEL:-}" \
    --arg glm_5h_pct  "${GLM_5H_PCT:-}" \
    --arg glm_w_pct   "${GLM_W_PCT:-}" \
    --arg git_branch  "$git_branch_fmt" \
    --arg git_ab      "$git_ab_fmt" \
    --arg runaway     "$runaway" \
    --arg cpu         "$cpu" \
    --arg thermals    "$thermals" \
    --arg free_mem    "$free_mem" \
    --arg disk        "$disk" \
    --arg battery     "$battery" \
    --arg line1       "$line1_full" \
    --arg line2       "$line2_full" \
    --arg line3       "$line3_full" \
    '$ARGS.named' \
    >> "$WIDGET_LOG_DIR/$(date +%Y-%m).jsonl" 2>/dev/null || true
fi
# ----- end widget-log -----
