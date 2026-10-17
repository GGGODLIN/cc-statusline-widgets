#!/usr/bin/env bash
# subagent-count.sh — how many subagents this session dispatched.
# Counts <transcript>/subagents/*.meta.json with spawnDepth 1, so an agent
# that spawns its own helpers still counts as the one dispatch you made.
# Live counts are deliberately absent: CC's own agent panel already shows
# what is running right now, and it disappears once the run ends — the
# cumulative total is the part no other surface keeps.
# usage: subagent-count.sh <transcript_path>
set -uo pipefail

none() { printf '🤖 -\n'; exit 0; }

tp="${1:-}"
[[ -n "$tp" ]] || none
sub="${tp%.jsonl}/subagents"
[[ -d "$sub" ]] || none

shopt -s nullglob
metas=("$sub"/*.meta.json)
shopt -u nullglob
(( ${#metas[@]} )) || none

matched=$(command grep -LE '"spawnDepth": ?([2-9]|[1-9][0-9]+)' "${metas[@]}" 2>/dev/null || true)
[[ -n "$matched" ]] || none
n=0
while IFS= read -r _line; do
  [[ -n "$_line" ]] && n=$(( n + 1 ))
done <<<"$matched"
(( n > 0 )) || none
printf '🤖 %s\n' "$n"
