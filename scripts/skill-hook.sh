#!/usr/bin/env bash
# CC hook: capture invoked skill name → /tmp/cc-widget-cache/skill.txt
# Wired to PreToolUse(matcher=Skill) and UserPromptSubmit.
# Logic mirrors ccstatusline --hook (sirmalloc/ccstatusline src/ccstatusline.ts).
set -uo pipefail

CACHE_DIR=/tmp/cc-widget-cache
mkdir -p "$CACHE_DIR"

input=$(cat)
event=$(jq -r '.hook_event_name // ""' <<<"$input" 2>/dev/null)
tool=$(jq -r '.tool_name // ""' <<<"$input" 2>/dev/null)

skill=""
if [[ "$event" == "PreToolUse" && "$tool" == "Skill" ]]; then
  skill=$(jq -r '.tool_input.skill // ""' <<<"$input" 2>/dev/null)
elif [[ "$event" == "UserPromptSubmit" ]]; then
  prompt=$(jq -r '.prompt // ""' <<<"$input" 2>/dev/null)
  if [[ "$prompt" =~ ^/([a-zA-Z0-9_:-]+)([[:space:]]|$) ]]; then
    skill="${BASH_REMATCH[1]}"
  fi
fi

if [[ -n "$skill" && "$skill" != "null" ]]; then
  printf '%s' "$skill" > "$CACHE_DIR/skill.txt.tmp" \
    && mv "$CACHE_DIR/skill.txt.tmp" "$CACHE_DIR/skill.txt"
fi
echo '{}'
