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
PURPLE=$'\033[38;5;141m'
RST=$'\033[0m'

input=$(cat)
jqr() { jq -r "$1" <<<"$input" 2>/dev/null; }

probe_cols() {
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
runaway_prefix=""
[[ -n "$runaway" ]] && runaway_prefix="$runaway | "

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
        | {
            hit: (if $tot > 0 then ($cr * 100 / $tot | floor) else -1 end),
            flushes: ([$usages[1:][]
              | (.cache_read_input_tokens // 0) as $r
              | (.cache_creation_input_tokens // 0) as $w
              | (.input_tokens // 0) as $i
              | ($r + $w + $i) as $t
              | select($t > 0 and ($r * 100 / $t) < 50)] | length),
            session_waste: $session_waste
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

      extras=""
      if (( flushes > 0 )); then
        extras="${YELLOW}${flushes}f${RST}"
      fi
      if (( waste > 0 )); then
        if   (( waste >= 1000000 )); then waste_fmt=$(awk "BEGIN { printf \"%.1fM\", $waste/1000000 }")
        elif (( waste >= 1000 ));    then waste_fmt=$(awk "BEGIN { printf \"%.0fk\", $waste/1000 }")
        else                              waste_fmt="$waste"
        fi
        if [[ -n "$extras" ]]; then
          extras="${extras}${GRAY}, ${RST}${YELLOW}${waste_fmt}${RST}"
        else
          extras="${YELLOW}${waste_fmt}${RST}"
        fi
      fi
      [[ -n "$extras" ]] && cache_hit_fmt="${cache_hit_fmt} ${GRAY}(${RST}${extras}${GRAY})${RST}"
    fi
  fi
fi

session_cost_usd=$(jqr '.cost.total_cost_usd // 0')
session_cost_fmt=$(awk -v c="$session_cost_usd" 'BEGIN { printf "$%.2f", c }')

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

line1="${runaway_prefix}${CYAN}$model_name${RST}"
[[ -n "$cache_hit_fmt" ]] && line1="${line1} | $cache_hit_fmt"
line1="${line1} | ${PURPLE}$skills_fmt${RST} | $git_branch_fmt $git_ab_fmt | ${GREEN}$session_cost_fmt${RST}"

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
    done < <(jq -r '.data.balance_infos[]? | "\(.currency)\t\(.total_balance)"' "$json" 2>/dev/null)
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

line2=""
if [[ -x "$HOME/.claude/scripts/usage-color.sh" ]]; then
  line2=$("$HOME/.claude/scripts/usage-color.sh" 2>/dev/null || echo "")
fi

ds_part=$(fmt_deepseek_balances "DS" 2>/dev/null || echo "")
mimo_plan=$(fmt_vendor_plan "mimo" 2>/dev/null || echo "")
mimo_bal=$(fmt_vendor_balance "mimo" "" 2.00 8.00 2>/dev/null || echo "")

if [[ -n "$ds_part" ]]; then
  [[ -n "$line2" ]] && line2="${line2}${BLUE} || ${RST}"
  line2="${line2}${ds_part}"
fi
if [[ -n "$mimo_plan" || -n "$mimo_bal" ]]; then
  [[ -n "$line2" ]] && line2="${line2}${BLUE} || ${RST}"
  line2="${line2}${BLUE}MiMo: ${RST}"
  [[ -n "$mimo_plan" ]] && line2="${line2}${mimo_plan}"
  [[ -n "$mimo_plan" && -n "$mimo_bal" ]] && line2="${line2}${BLUE} | ${RST}"
  [[ -n "$mimo_bal" ]] && line2="${line2}${mimo_bal}"
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
ctx_bar_fmt="⛁ [${bar}] ${ctx_used_k}k/${ctx_total_k}k (${ctx_used_int}%)"

# read daemon-written widgets
cpu=$(cat "$CACHE_DIR/cpu.txt" 2>/dev/null || printf 'CPU: ?')
thermals=$(cat "$CACHE_DIR/thermals.txt" 2>/dev/null || printf '🌡️ ?')
free_mem=$(cat "$CACHE_DIR/memory.txt" 2>/dev/null || printf 'Mem: ?')
disk=$(cat "$CACHE_DIR/disk.txt" 2>/dev/null || printf '💾 ?')
battery=$(cat "$CACHE_DIR/battery.txt" 2>/dev/null || printf '🔋?')

line3="${BLUE}$ctx_bar_fmt${RST} | $cpu | $thermals | $free_mem | $disk | $battery"

# ----- Truncate all lines to fit terminal width -----
cols=$(probe_cols)
effective_cols=20
if [[ -n "$cols" && "$cols" -gt 0 ]]; then
  effective_cols=$(( cols - 6 ))
  (( effective_cols < 20 )) && effective_cols=20
fi

line1_full="$line1"
line2_full="$line2"
line3_full="$line3"
line1=$(fit_to_cols "$effective_cols" "$line1")
[[ -n "$line2" ]] && line2=$(fit_to_cols "$effective_cols" "$line2")
line3=$(fit_to_cols "$effective_cols" "$line3")

if [[ -n "$line2" ]]; then
  printf '%s\n%s\n%s\n' "$line1" "$line2" "$line3"
else
  printf '%s\n%s\n' "$line1" "$line3"
fi

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
    --arg ctx_pct     "$ctx_used_pct" \
    --arg ctx_tokens  "$ctx_used_tokens" \
    --arg skill       "$skill_name" \
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
