#!/usr/bin/env bash
# subagent-statusline.sh — CC `subagentStatusLine` command.
# Pure collector: emits no row override (panel keeps default rendering),
# writes the live task roster to cache for wrapper.sh to read.
set -uo pipefail

CACHE_DIR=/tmp/cc-widget-cache
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

input=$(cat)
sid=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null)
[[ -n "$sid" && "$sid" != "null" ]] || exit 0

out="$CACHE_DIR/subagents-$sid.json"
tmp="$out.tmp.$$"

jq -c --argjson ts "$(date +%s)" '
  (.tasks // []) as $t
  | ([$t[] | select(((.status // "") | ascii_downcase)
      | test("complet|finish|done|fail|error|cancel|abort|kill|timeout|reject") | not)]) as $live
  | {
      ts: $ts,
      active: ($live | length),
      visible: ($t | length),
      statuses: ([$t[] | .status // "?"] | unique),
      types: ([$live[] | .type // .name // "?"] | sort)
    }
' <<<"$input" > "$tmp" 2>/dev/null && mv "$tmp" "$out" || rm -f "$tmp"

exit 0
