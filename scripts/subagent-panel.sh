#!/usr/bin/env bash
# subagent-panel.sh — CC `subagentStatusLine` command. Restyles each local agent row of the
# panel under the prompt as pills matching wrapper.sh (layout adapted from Nanako0129/coralline).
#
# CC 2.1.288 reruns this every 5s (hard-coded), so elapsed time steps in 5s instead of CC's own
# per-second timer. A row we don't print keeps CC's rendering, which is why bad input exits
# quietly and non-agent rows are skipped. CC still draws the status dot left of our content.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

WT_STYLE="pill"
WT_THEME="claude-coral"
WT_BAR_FILL="▰"
WT_BAR_EMPTY="▱"
PANEL_BAR_WIDTH=10
PANEL_MIN_TITLE=24  # below this the whole panel drops its context bars to give titles room

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
# same palette slots wrapper.sh uses: ctx / system / model / quota / agents
WT_BG_TITLE=${WT_BG_CTX:-${VL_BG_CTX:-238}}
WT_BG_LABEL=${WT_BG_SYS:-${VL_BG_LINES:-240}}
WT_BG_MODEL=${WT_BG_MODEL:-${VL_BG_MODEL:-173}}
WT_BG_USAGE=${WT_BG_USAGE:-${VL_BG_7D:-236}}
WT_BG_AGENTS=${WT_BG_AGENTS:-${VL_BG_AGENTS:-${VL_BG_DURATION:-60}}}

RST=$'\033[0m'
BOLD=$'\033[1m'
NORM=$'\033[22m'
CAP_L=$(printf '\xee\x82\xb6')
CAP_R=$(printf '\xee\x82\xb4')
SEP=$(printf '\xee\x82\xb0')

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

render_range() {  # RB/RT[$1..$2] as one row → stdout (copy of wrapper.sh's renderer)
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

# Display width (CJK and emoji count 2, ANSI 0), or with a max: the text cut to fit, ending in "…".
textw() {
  perl -CSDA -e '
    sub cw { my $o = shift;
      return 0 if $o == 0x200D || ($o >= 0x0300 && $o <= 0x036F) || ($o >= 0xFE00 && $o <= 0xFE0F);
      return 2 if ($o >= 0x1100 && $o <= 0x115F) || ($o >= 0x2E80 && $o <= 0xA4CF)
                || ($o >= 0xAC00 && $o <= 0xD7A3) || ($o >= 0xF900 && $o <= 0xFAFF)
                || ($o >= 0xFF00 && $o <= 0xFF60) || ($o >= 0x1F300 && $o <= 0x1F9FF);
      return 1 }
    my ($text, $max) = @ARGV;
    (my $plain = $text) =~ s/\e\[[0-9;]*[a-zA-Z]//g;
    my $w = 0; $w += cw(ord($_)) for split //, $plain;
    if (!defined $max) { print $w; exit }
    if ($w <= $max) { print $text; exit }
    my ($out, $vis) = ("", 0);
    for my $c (split //, $plain) { my $cw = cw(ord($c)); last if $vis + $cw > $max - 1; $out .= $c; $vis += $cw }
    print $out, "\x{2026}";
  ' -- "$@"
}

kfmt() { printf '%dk' $(( ($1 + 500) / 1000 )); }

model_short() {
  local m=${1%%\[*} fam
  m=${m#claude-}
  if [[ "$m" =~ ^(opus|sonnet|haiku|fable)-([0-9]+)-([0-9]+)(-[0-9]{8})?$ ]]; then
    case "${BASH_REMATCH[1]}" in
      opus) fam=Opus ;; sonnet) fam=Sonnet ;; haiku) fam=Haiku ;; fable) fam=Fable ;;
    esac
    printf '%s %s.%s' "$fam" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  else
    printf '%s' "${1%%\[*}"
  fi
}

dur() {
  local s=$1
  if   (( s < 60 ));   then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
  else                      printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 )); fi
}

input=$(cat)
# CC can hand over several payloads in one read; only the newest matters.
fields=$(jq -rs '
  (map(select(type == "object")) | last // {}) as $p
  | ($p.tasks // [])[]
  | select(.type == "local_agent" and ((.id // "") | test("^[A-Za-z0-9._-]+$")))
  | [ .id, (.status // ""), (.name // ""), (.label // .description // ""), (.model // ""),
      (.effort // "" | if type == "string" then . else "" end),
      (.contextWindowSize // 0 | floor), (.tokenCount // 0 | floor),
      (.startTime // null
        | if type == "number" then (if . > 100000000000 then . / 1000 else . end | floor)
          elif type == "string" then (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601? // "")
          else "" end),
      ((.tokenSamples // []) | if length >= 2 then (.[-1] - .[-2] | floor) else "" end),
      ($p.transcript_path // ""), ($p.columns // 0 | floor) ]
  | map(tostring | gsub("[\u0000-\u001f]"; " ")) | join("\u001f")
' <<<"$input" 2>/dev/null) || exit 0
[[ -n "$fields" ]] || exit 0

NOW=$(date +%s)
IDS=() ; TITLE_ROLE=() ; TITLE_LABEL=() ; TITLE_FG=() ; SEG_MODEL=() ; SEG_CTX_BAR=() ; SEG_CTX=() ; SEG_TAIL=()
panel_cols=0

while IFS=$'\037' read -r id status name label model effort cws tok start delta tpath cols; do
  # read clears every variable on its final EOF pass, so the width is kept outside the loop vars.
  panel_cols=$cols
  base="${tpath%.jsonl}/subagents/agent-${id}"

  role="$name"
  if [[ -z "$role" && -r "$base.meta.json" ]]; then
    meta=$(head -c 4096 "$base.meta.json")
    [[ "$meta" =~ \"agentType\":[[:space:]]*\"([A-Za-z0-9._:-]+)\" ]] && role="${BASH_REMATCH[1]}"
  fi
  [[ -n "$role" ]] || role="agent"

  # The effort CC actually sent sits on the first assistant line (absent on models without
  # effort, like Haiku); the payload only has the definition's configured value.
  applied="" ; answered=0
  if [[ -r "$base.jsonl" ]]; then
    n=0
    while (( n < 64 )) && IFS= read -r line; do
      n=$(( n + 1 ))
      [[ "$line" == *'"type":"assistant"'* ]] || continue
      answered=1
      [[ "$line" =~ \"effort\":[[:space:]]*\"(low|medium|high|xhigh|max)\" ]] && applied="${BASH_REMATCH[1]}"
      break
    done < "$base.jsonl"
  fi
  (( answered )) || applied="$effort"
  [[ "$applied" =~ ^(low|medium|high|xhigh|max)$ ]] || applied=""

  case "$status" in
    running|in_progress|active) title_fg="$VL_FG_TEXT" ;;
    completed|success|done)     title_fg="$VL_FG_OK" ;;
    failed|error|killed|cancelled) title_fg="$VL_FG_HOT" ;;
    *)                          title_fg="$VL_FG_DIM" ;;
  esac

  seg_model=""
  if [[ -n "$model" ]]; then
    seg_model="${BOLD}◆ $(model_short "$model")${NORM}"
    [[ -n "$applied" ]] && seg_model="${seg_model} (${applied})"
  fi

  seg_ctx="" ; seg_bar=""
  if (( tok > 0 )); then
    if (( cws > 0 )); then
      pct=$(( tok * 100 / cws )) ; (( pct > 100 )) && pct=100
      c=$(fg "$(pct_color "$pct")")
      filled=$(( (pct * PANEL_BAR_WIDTH + 50) / 100 ))
      for ((i=0; i<PANEL_BAR_WIDTH; i++)); do
        (( i < filled )) && seg_bar+="$WT_BAR_FILL" || seg_bar+="$WT_BAR_EMPTY"
      done
      seg_ctx="${c}⛁ $(kfmt "$tok")/$(kfmt "$cws")"
      seg_bar="${c}⛁ ${seg_bar} $(kfmt "$tok")/$(kfmt "$cws")"
    else
      seg_ctx="⛁ $(kfmt "$tok")"
      seg_bar="$seg_ctx"
    fi
  fi

  tail=""
  case "$status" in
    running|in_progress|active)
      [[ "$start" =~ ^[0-9]+$ ]] && (( NOW >= start )) && tail="⧖ $(dur $(( NOW - start )))"
      if [[ "$delta" =~ ^[0-9]+$ ]]; then
        if (( delta == 0 )); then grow="$(fg "$VL_FG_DIM")+0"
        elif (( delta >= 1000 )); then grow="$(fg "$VL_FG_OK")+$(awk -v d="$delta" 'BEGIN { printf "%.1fk", d / 1000 }')"
        else grow="$(fg "$VL_FG_OK")+${delta}"; fi
        tail="${tail:+$tail }$grow"
      fi ;;
    completed|success|done)        tail="$(fg "$VL_FG_OK")✓" ;;
    failed|error|killed|cancelled) tail="$(fg "$VL_FG_HOT")✗" ;;
  esac

  IDS+=("$id") ; TITLE_ROLE+=("$role") ; TITLE_LABEL+=("$label") ; TITLE_FG+=("$title_fg")
  SEG_MODEL+=("$seg_model") ; SEG_CTX_BAR+=("$seg_bar") ; SEG_CTX+=("$seg_ctx") ; SEG_TAIL+=("$tail")
done <<<"$fields"

build() {  # $1=row index $2=1 for the barred context → RB/RT; the label pill is a 1-col placeholder
  local i=$1
  RB=("$WT_BG_TITLE") ; RT=("$(fg "${TITLE_FG[i]}")${BOLD}${TITLE_ROLE[i]}${NORM}")
  [[ -n "${TITLE_LABEL[i]}" ]] && { RB+=("$WT_BG_LABEL"); RT+=("X"); }
  [[ -n "${SEG_MODEL[i]}" ]] && { RB+=("$WT_BG_MODEL"); RT+=("${SEG_MODEL[i]}"); }
  if (( $2 )); then
    [[ -n "${SEG_CTX_BAR[i]}" ]] && { RB+=("$WT_BG_USAGE"); RT+=("${SEG_CTX_BAR[i]}"); }
  else
    [[ -n "${SEG_CTX[i]}" ]] && { RB+=("$WT_BG_USAGE"); RT+=("${SEG_CTX[i]}"); }
  fi
  [[ -n "${SEG_TAIL[i]}" ]] && { RB+=("$WT_BG_AGENTS"); RT+=("${SEG_TAIL[i]}"); }
}

row_width() { textw "$(render_range 0 $(( ${#RB[@]} - 1 )))"; }

# One bar decision for the whole panel, so rows don't disagree with each other. The role pill
# plus whatever is left for the label must reach PANEL_MIN_TITLE; the placeholder's 1 col
# doubles as a right margin.
use_bar=1
if (( panel_cols > 0 )); then
  for ((r=0; r<${#IDS[@]}; r++)); do
    build "$r" 1
    (( $(textw "${TITLE_ROLE[r]}") + panel_cols - $(row_width) < PANEL_MIN_TITLE )) && { use_bar=0; break; }
  done
fi

for ((r=0; r<${#IDS[@]}; r++)); do
  build "$r" "$use_bar"
  label="${TITLE_LABEL[r]}"
  if [[ -n "$label" ]]; then
    if (( panel_cols > 0 )); then
      room=$(( panel_cols - $(row_width) ))
      if (( room >= 4 )); then
        label=$(textw "$label" "$room")
      else
        label=""
      fi
    fi
    if [[ -n "$label" ]]; then
      RT[1]="$label"
    else
      # no room for even a stub: drop the label pill, then shorten the role if it still overflows
      RB=("${RB[0]}" "${RB[@]:2}") ; RT=("${RT[0]}" "${RT[@]:2}")
    fi
  fi
  if (( panel_cols > 0 )) && (( $(row_width) > panel_cols )); then
    RT[0]="X"
    room=$(( panel_cols - $(row_width) + 1 ))
    (( room < 1 )) && room=1
    RT[0]="$(fg "${TITLE_FG[r]}")${BOLD}$(textw "${TITLE_ROLE[r]}" "$room")${NORM}"
  fi
  jq -nc --arg id "${IDS[r]}" --arg content "$(render_range 0 $(( ${#RB[@]} - 1 )))" '{id: $id, content: $content}'
done
exit 0
