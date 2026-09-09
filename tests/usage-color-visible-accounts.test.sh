#!/usr/bin/env bash

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/usage-color.sh"
PASS=0
FAIL=0
TMP_HOME=$(mktemp -d)
trap 'rm -rf "$TMP_HOME"' EXIT

ok() {
  printf '  ✅ %s\n' "$1"
  PASS=$((PASS + 1))
}

bad() {
  printf '  ❌ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
  FAIL=$((FAIL + 1))
}

make_cache() {
  local email=$1 five=$2 seven=$3 path
  path="$TMP_HOME/.claude/cache/quota-${email//@/_at_}.json"
  python3 - "$path" "$email" "$five" "$seven" <<'PY'
import json
import sys

path, email, five, seven = sys.argv[1:]
with open(path, 'w') as handle:
  json.dump({
    'fetched_at': '12:00:00',
    'email': email,
    'org_id': 'test',
    'data': {
      'five_hour': {'utilization': float(five), 'resets_at': None},
      'seven_day': {'utilization': float(seven), 'resets_at': None},
      'limits': [],
    },
  }, handle)
PY
}

mkdir -p "$TMP_HOME/.claude/cache"
printf '%s\n' '{"oauthAccount":{"emailAddress":"software.agent@example.com"}}' > "$TMP_HOME/.claude.json"
make_cache 'software.agent@example.com' 10 20
make_cache 'side@example.com' 30 40
make_cache 'qwe70301@gmail.com' 50 60
make_cache 'unknown' 70 80
printf '12:01:00\tstatus-only\n' > "$TMP_HOME/.claude/cache/quota-status_at_example.com.status"
printf '12:02:00\tduplicate-status\n' > "$TMP_HOME/.claude/cache/quota-side_at_example.com.status"

printf '== machine-readable visible accounts ==\n'
JSON_OUTPUT=$(HOME="$TMP_HOME" bash "$SCRIPT" --visible-accounts-json)
if printf '%s' "$JSON_OUTPUT" | jq -e '.accounts | type == "array"' >/dev/null 2>&1; then
  ok 'output is valid JSON with an accounts array'
else
  bad 'machine-readable JSON' 'valid object with accounts array' "$JSON_OUTPUT"
fi

EMAILS=$(printf '%s' "$JSON_OUTPUT" | jq -r '.accounts | map(.email) | join(",")' 2>/dev/null)
EXPECTED_EMAILS='software.agent@example.com,side@example.com,status@example.com'
if [[ "$EMAILS" == "$EXPECTED_EMAILS" ]]; then
  ok 'visible account order matches rendered account order'
else
  bad 'visible account order' "$EXPECTED_EMAILS" "$EMAILS"
fi

CACHE_PATHS=$(printf '%s' "$JSON_OUTPUT" | jq -r '.accounts | map(.cache) | join(",")' 2>/dev/null)
EXPECTED_CACHE_PATHS="$TMP_HOME/.claude/cache/quota-software.agent_at_example.com.json,$TMP_HOME/.claude/cache/quota-side_at_example.com.json,$TMP_HOME/.claude/cache/quota-status_at_example.com.json"
if [[ "$CACHE_PATHS" == "$EXPECTED_CACHE_PATHS" ]]; then
  ok 'each visible account carries its canonical quota cache path'
else
  bad 'quota cache paths' "$EXPECTED_CACHE_PATHS" "$CACHE_PATHS"
fi

printf '== normal statusline output ==\n'
NORMAL_OUTPUT=$(HOME="$TMP_HOME" bash "$SCRIPT")
PLAIN_OUTPUT=$(printf '%s' "$NORMAL_OUTPUT" | perl -pe 's/\e\[[0-9;]*m//g')
EXPECTED_PLAIN='S: 10% — | 20%  — || side ⚠ 30%|40% || status | ⚠ status-only @ 12:01:00'
if [[ "$PLAIN_OUTPUT" == "$EXPECTED_PLAIN" ]]; then
  ok 'normal statusline rendering remains unchanged'
else
  bad 'normal statusline rendering' "$EXPECTED_PLAIN" "$PLAIN_OUTPUT"
fi

# side 同時有 cache 與 .status：畫數字 + 帳號名旁一個 ⚠，不整格藏起來。
# 非當前帳號走 compact 版：只有 5h|weekly 兩個數字，沒有 reset 時間。
# status 只有 .status 沒 cache：沒有數字可畫，維持整格錯誤訊息。
if [[ "$PLAIN_OUTPUT" == *'side ⚠ 30%|40%'* ]]; then
  ok 'a failed fetch beside a usable cache degrades to a marker, not a blank pill'
else
  bad 'stale-status degradation' 'side ⚠ 30%|40%' "$PLAIN_OUTPUT"
fi

# 當前 session 的帳號保留完整資訊（reset 時間），非當前的不留。
if [[ "$PLAIN_OUTPUT" == 'S: 10% — | 20%  —'* ]]; then
  ok 'the session account keeps its reset times while side accounts drop them'
else
  bad 'main account detail' 'S: 10% — | 20%  —' "$PLAIN_OUTPUT"
fi

if [[ "$PLAIN_OUTPUT" == *'status | ⚠ status-only @ 12:01:00'* ]]; then
  ok 'an account with no cache at all still shows the full failure reason'
else
  bad 'cacheless failure' 'status | ⚠ status-only @ 12:01:00' "$PLAIN_OUTPUT"
fi

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
