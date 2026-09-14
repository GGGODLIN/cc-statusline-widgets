#!/usr/bin/env bash
# subagent-count.sh — "<active>/<total>" subagents for one session.
# total: directly-dispatched subagents (spawnDepth 1) recorded under
#        <transcript>/subagents/*.meta.json
# active: live roster from subagent-statusline.sh cache when fresh,
#         else meta toolUseId with no tool_result in the transcript yet.
# usage: subagent-count.sh <transcript_path> [session_id]
set -uo pipefail

CACHE_DIR=/tmp/cc-widget-cache
STALE_SEC=${SUBAGENT_STALE_SEC:-600}
B_FRESH_SEC=${SUBAGENT_B_FRESH_SEC:-15}

tp="${1:-}"
sid="${2:-}"

emit() {
  if [[ "${2:-0}" == "0" ]]; then printf '🤖 -\n'; else printf '🤖 %s/%s\n' "$1" "$2"; fi
  exit 0
}

[[ -n "$tp" && -f "$tp" ]] || emit 0 0
sess="${tp%.jsonl}"
sub="$sess/subagents"
[[ -d "$sub" ]] || emit 0 0

shopt -s nullglob
metas=("$sub"/*.meta.json)
shopt -u nullglob
(( ${#metas[@]} )) || emit 0 0

memo="$CACHE_DIR/subagents-memo-${tp##*/}.memo"
key="$(stat -f '%m' "$sub" 2>/dev/null) $(stat -f '%m %z' "$tp" 2>/dev/null) ${#metas[@]}"
data=""
if [[ -f "$memo" ]]; then
  { read -r memo_key; read -r memo_data; } < "$memo"
  [[ "$memo_key" == "$key" ]] && data="$memo_data"
fi

if [[ -z "$data" ]]; then
  rows=$(jq -r 'select((.spawnDepth // 1) == 1) | [(.toolUseId // "-"), input_filename] | @tsv' \
    "${metas[@]}" 2>/dev/null)
  total=0
  active=0
  if [[ -n "$rows" ]]; then
    done_ids=$(command grep -oh '"tool_use_id":"[^"]*"' "$tp" 2>/dev/null | sed 's/.*:"//;s/"$//' | sort -u)
    now=$(date +%s)
    while IFS=$'\t' read -r tuid mfile; do
      [[ -n "$mfile" ]] || continue
      total=$((total + 1))
      aid="${mfile##*/agent-}"; aid="${aid%.meta.json}"
      if [[ "$tuid" == "-" ]]; then
        command grep -q "${aid}</task-id>.*<status>completed</status>" "$tp" 2>/dev/null && continue
      else
        command grep -qxF "$tuid" <<<"$done_ids" && continue
      fi
      mt=$(stat -f '%m' "$sub/agent-$aid.jsonl" 2>/dev/null || printf '%s' "$now")
      (( now - mt > STALE_SEC )) && continue
      active=$((active + 1))
    done <<<"$rows"
  fi
  data="$active $total"
  mkdir -p "$CACHE_DIR" 2>/dev/null
  printf '%s\n%s\n' "$key" "$data" > "$memo" 2>/dev/null
fi

read -r active total <<<"$data"

if [[ -n "$sid" ]]; then
  live="$CACHE_DIR/subagents-$sid.json"
  if [[ -f "$live" ]]; then
    b=$(jq -r --argjson now "$(date +%s)" --argjson w "$B_FRESH_SEC" \
      'if ($now - (.ts // 0)) <= $w then (.active // 0) else "" end' "$live" 2>/dev/null)
    [[ "$b" =~ ^[0-9]+$ ]] && active="$b"
  fi
fi

(( active > total )) && total="$active"
emit "$active" "$total"
