#!/usr/bin/env bash
# CC hook: capture invoked skill name → /tmp/cc-widget-cache/skill.txt
# Wired to PreToolUse(matcher=Skill) and UserPromptSubmit.
# Logic mirrors ccstatusline --hook (sirmalloc/ccstatusline src/ccstatusline.ts).
set -uo pipefail

CACHE_DIR="${CC_WIDGET_CACHE_DIR:-/tmp/cc-widget-cache}"

input=$(cat)
if [[ "$input" != *PreToolUse* && "$input" != *UserPromptSubmit* ]]; then
  echo '{}'
  exit 0
fi

event=""
tool=""
session_id=""
tool_skill=""
prompt=""
{
  IFS= read -r -d '' event || true
  IFS= read -r -d '' tool || true
  IFS= read -r -d '' session_id || true
  IFS= read -r -d '' tool_skill || true
  IFS= read -r -d '' prompt || true
} < <(jq -j '
  def clean_str: if type == "string" then gsub("[\u0000-\u001f\u007f]"; "") else "" end;
  def str_no_nul: if type == "string" then gsub("\u0000"; "") else "" end;
  ((try .hook_event_name catch null) | clean_str), "\u0000",
  ((try .tool_name catch null) | clean_str), "\u0000",
  ((try .session_id catch null) | clean_str), "\u0000",
  ((try .tool_input.skill catch null) | clean_str), "\u0000",
  ((try .prompt catch null) | str_no_nul), "\u0000"
' <<<"$input" 2>/dev/null)

skill=""
if [[ "$event" == "PreToolUse" && "$tool" == "Skill" ]]; then
  skill="$tool_skill"
elif [[ "$event" == "UserPromptSubmit" ]]; then
  if [[ "$prompt" =~ ^/([a-zA-Z0-9_:-]+)([[:space:]]|$) ]]; then
    skill="${BASH_REMATCH[1]}"
  fi
fi

if [[ -n "$skill" && "$skill" != "null" && "$session_id" =~ ^[A-Za-z0-9._-]+$ && "$session_id" != "." && "$session_id" != ".." ]]; then
  case "$skill" in
    clear|compact|reload-plugins|help|exit|quit|model|effort|fast|config|status|permissions|hooks|mcp|plugin|login|logout|doctor|memory|cost|resume|rename|color|vim|theme) ;;
    *)
      mkdir -p "$CACHE_DIR" 2>/dev/null || true
      file="$CACHE_DIR/skill-${session_id}.txt"
      if tmp_file=$(mktemp "$CACHE_DIR/.skill-${session_id}.XXXXXX" 2>/dev/null); then
        if printf '%s' "$skill" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$file" 2>/dev/null; then
          :
        else
          rm -f "$tmp_file"
        fi
      fi
      ;;
  esac
fi
echo '{}'
