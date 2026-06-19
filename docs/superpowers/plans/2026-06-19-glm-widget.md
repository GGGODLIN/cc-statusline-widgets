# GLM Coding Plan 用量 widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display a GLM Coding Plan (z.ai) quota pill on Claude Code statusline line 2, in front of the DeepSeek pill, mirroring Anthropic's `<Tier>: X% Nm | X% Nd Nh` format.

**Architecture:** Two-repo coordinated change. `cc-quota-fetcher` (chrome extension) picks up z.ai API key, polls `https://api.z.ai/api/monitor/usage/quota/limit` on the existing 30s alarm tick, and writes the raw `limits[]` array to `~/.claude/cache/vendor-glm-<pid>.json` via the existing native messaging pipeline. `cc-statusline-widgets` (this repo) parses the cache in `wrapper.sh` and renders a pill on line 2.

**Tech Stack:** Chrome MV3 extension (background.js, popup.html/js, manifest), Python native messaging receiver, bash + jq + ANSI rendering.

**Spec:** `docs/superpowers/specs/2026-06-19-glm-widget-design.md` (commit `a01ec56`).

## Global Constraints

- **Two repos:**
  - Fetcher: `~/Desktop/projects/cc-quota-fetcher/`
  - Wrapper: `~/Desktop/projects/cc-statusline-widgets/` (this repo, owns spec + plan)
- **Order:** Fetcher tasks (T1, T2) must populate cache before wrapper tasks (T3-T5) can e2e-verify
- **Chrome host_permission re-grant:** After reloading the extension with new `https://api.z.ai/*` host_permission, manually approve via `chrome://extensions` → cc-quota-fetcher → Details → Site access → Allow on `api.z.ai`
- **Token source:** `ZAI_API_KEY` (already exists in `~/.zsh_secrets`, length 49). Same key z.ai issues for `ANTHROPIC_AUTH_TOKEN`
- **Auth header:** `Authorization: <token>` — **no `Bearer ` prefix** (z.ai quirk, breaks if added)
- **`credentials: 'omit'`** for GLM fetch (pure API, no cookie mixing)
- **base URL:** hard-code `https://api.z.ai`. `open.bigmodel.cn` is out of scope this round
- **profile_id:** share existing cc-quota-fetcher `chrome.storage.local.profile_id` (single chrome profile assumption)
- **5h rolling sentinel:** `nextResetTime` is absent for 5h tokens → countdown renders as `0m`, never fabricate a fake reset time
- **Pill format:** `<Tier>: X% 0m | X% Nd Nh`, weekly segment conditional (omit `| ...` if no weekly entry in `limits[]`)
- **Threshold (5-stage):** ≥100 `RED_BOLD` / ≥80 `RED` / ≥50 `YELLOW` / ≥30 `BLUE` / <30 `GREEN`
- **Runtime deploy:** wrapper changes require `bash scripts/install.sh` (or single-file `cp scripts/wrapper.sh ~/.claude/scripts/cc-statusline/wrapper.sh`). CC reads the runtime copy at `~/.claude/scripts/cc-statusline/wrapper.sh`, NOT the repo file
- **Verify** runtime copy:
  ```
  echo '{"model":{"display_name":"sonnet"},"context_window":{"used_percentage":0,"context_window_size":200000,"current_usage":{}}}' | bash ~/.claude/scripts/cc-statusline/wrapper.sh
  ```
- **widget-log schema sync:** new widget MUST add corresponding `--arg` to `wrapper.sh` widget-log block
- **Conventional Commits** (feat / docs / refactor / fix)
- **No comments in code** (CLAUDE.md global rule)
- **2-space indent**
- **ES modules** for chrome extension `.js`
- **Vibe coding repo policy** (project CLAUDE.md): `git add` / `commit` / `push` are auto-OK without per-step confirm

---

## File Structure

| File | Repo | Action | Notes |
|---|---|---|---|
| `extension/popup.html` | cc-quota-fetcher | Modify (line 17-22) | Add GLM checkbox + key input |
| `extension/popup.js` | cc-quota-fetcher | Modify | Add 'glm' to vendor list, glm_api_key handler |
| `extension/background.js` | cc-quota-fetcher | Modify | `GLM_QUOTA_URL`, `fetchGlmQuota`, `VENDOR_DEFAULTS`, `tick()` |
| `extension/manifest.json` | cc-quota-fetcher | Modify (line 27-31) | Add `https://api.z.ai/*` to host_permissions |
| `native-host/quota-receiver.py` | cc-quota-fetcher | Modify (line 65) | Add `'glm'` to `VALID_VENDORS` |
| `scripts/wrapper.sh` | cc-statusline-widgets | Modify (multi) | RED_BOLD, helpers, fmt_glm_quota, push_seg, widget-log |

No new files. Everything reuses existing structure.

---

## Task 1: fetcher — popup UI for GLM (HTML + JS)

**Repo:** `cc-quota-fetcher`

**Files:**
- Modify: `extension/popup.html:15-23`
- Modify: `extension/popup.js:2,15,27-32` (and add glm key handler section)

**Interfaces:**
- Produces: `chrome.storage.local.glm_api_key` (string), `chrome.storage.local.vendor_enabled.glm` (boolean)
- Consumed by: Task 2 (`background.js` reads both)

- [ ] **Step 1: Add GLM row to popup.html**

Edit `extension/popup.html`. Replace the body section (line 15-23):

```html
<body>
<h3>CC Quota Fetcher</h3>
<label><input type="checkbox" id="deepseek" checked> DeepSeek</label>
<label><input type="checkbox" id="mimo" checked> MiMo</label>
<label><input type="checkbox" id="glm" checked> GLM (z.ai)</label>
<div class="field">
  <div class="field-label">DeepSeek API Key</div>
  <input type="text" id="ds-key" placeholder="sk-...">
</div>
<div class="field">
  <div class="field-label">GLM API Key (z.ai)</div>
  <input type="text" id="glm-key" placeholder="z.ai token (no Bearer prefix)">
</div>
<div class="status" id="status"></div>
<script src="popup.js"></script>
</body>
```

- [ ] **Step 2: Wire popup.js for glm checkbox + key**

Edit `extension/popup.js`. Replace the full file with:

```js
const KEY = 'vendor_enabled';
const DEFAULT = { deepseek: true, mimo: true, glm: true };

const load = async () => {
  const stored = await chrome.storage.local.get(KEY);
  return Object.assign({}, DEFAULT, stored[KEY] ?? {});
};

const save = async (cfg) => {
  await chrome.storage.local.set({ [KEY]: cfg });
};

const init = async () => {
  const cfg = await load();
  for (const vendor of ['deepseek', 'mimo', 'glm']) {
    const cb = document.getElementById(vendor);
    cb.checked = cfg[vendor] !== false;
    cb.addEventListener('change', async () => {
      cfg[vendor] = cb.checked;
      await save(cfg);
      if (!cb.checked) {
        chrome.runtime.sendMessage({ type: 'vendor-disable', vendor });
      }
    });
  }

  const dsKey = document.getElementById('ds-key');
  const dsStored = await chrome.storage.local.get('deepseek_api_key');
  dsKey.value = dsStored.deepseek_api_key ?? '';
  dsKey.addEventListener('change', async () => {
    await chrome.storage.local.set({ deepseek_api_key: dsKey.value.trim() });
  });

  const glmKey = document.getElementById('glm-key');
  const glmStored = await chrome.storage.local.get('glm_api_key');
  glmKey.value = glmStored.glm_api_key ?? '';
  glmKey.addEventListener('change', async () => {
    await chrome.storage.local.set({ glm_api_key: glmKey.value.trim() });
  });

  const profileId = (await chrome.storage.local.get('profile_id')).profile_id ?? '?';
  document.getElementById('status').textContent = `profile: ${profileId}`;
};

init();
```

- [ ] **Step 3: Manual verify in chrome (popup only, no fetch yet)**

```bash
cd ~/Desktop/projects/cc-quota-fetcher
```

In Chrome:
1. Go to `chrome://extensions`
2. Find cc-quota-fetcher → click **Reload**
3. Click the extension icon → popup opens
4. Expected: see three checkboxes (DeepSeek / MiMo / **GLM (z.ai)**) all checked, two key fields (DeepSeek + **GLM**), and profile id text at bottom
5. Type a dummy value into GLM key field, blur, reopen popup → value persists

- [ ] **Step 4: Commit**

```bash
cd ~/Desktop/projects/cc-quota-fetcher
git add extension/popup.html extension/popup.js
git commit -m "feat(popup): add GLM (z.ai) vendor checkbox + API key field"
```

---

## Task 2: fetcher — background.js GLM fetch + manifest + receiver

**Repo:** `cc-quota-fetcher`

**Files:**
- Modify: `extension/background.js` (add const, function, alarm tick branch, VENDOR_DEFAULTS)
- Modify: `extension/manifest.json:27-31` (add host_permission)
- Modify: `native-host/quota-receiver.py:65` (add `'glm'` to VALID_VENDORS)

**Interfaces:**
- Consumes: `chrome.storage.local.glm_api_key` (from Task 1), `chrome.storage.local.vendor_enabled.glm` (from Task 1)
- Produces: `~/.claude/cache/vendor-glm-<pid>.json` with shape `{vendor, profile_id, data: {level, limits[]}}` — consumed by wrapper Task 4 (`fmt_glm_quota`)

- [ ] **Step 1: Add GLM constants + fetcher function to background.js**

Edit `extension/background.js`. Add `GLM_QUOTA_URL` const right after the existing `MIMO_PLAN_URL` line (around line 7):

```js
const GLM_QUOTA_URL = 'https://api.z.ai/api/monitor/usage/quota/limit';
```

Change `VENDOR_DEFAULTS` (line 33) to include `glm`:

```js
const VENDOR_DEFAULTS = { deepseek: true, mimo: true, glm: true };
```

After `getDeepSeekApiKey` (around line 43), add:

```js
const getGlmApiKey = async () => {
  const stored = await chrome.storage.local.get('glm_api_key');
  return stored.glm_api_key ?? '';
};
```

After `fetchMiMoPlan` (around line 165, before `ensureAlarm`), add `fetchGlmQuota`:

```js
const fetchGlmQuota = async (pid) => {
  const apiKey = await getGlmApiKey();
  if (!apiKey) return;
  try {
    const { status, body } = await fetchJson(GLM_QUOTA_URL, {
      credentials: 'omit',
      headers: {
        'Authorization': apiKey,
        'Accept-Language': 'en-US,en',
        'Content-Type': 'application/json'
      }
    });
    if (status === 200 && body?.success && body.data) {
      await send({ type: 'vendor-balance', profile_id: pid, vendor: 'glm', fetched_at: ts(), data: {
        level: body.data.level ?? 'glm',
        limits: body.data.limits ?? []
      }});
    } else {
      const reason = body?.msg ? `msg ${body.msg}` : `HTTP ${status}`;
      await send({ type: 'vendor-status', profile_id: pid, vendor: 'glm', fetched_at: ts(), reason });
    }
  } catch (e) {
    await send({ type: 'vendor-status', profile_id: pid, vendor: 'glm', fetched_at: ts(), reason: 'network' });
  }
};
```

Add the GLM branch to `tick()` (after the mimo block, around line 181):

```js
const tick = async () => {
  await ensureAlarm();
  const pid = await getProfileId();
  const cfg = await getVendorConfig();
  await fetchAnthropicQuota(pid);
  if (cfg.deepseek) await fetchDeepSeekBalance(pid);
  if (cfg.mimo) {
    await fetchMiMoBalance(pid);
    await fetchMiMoPlan(pid);
  }
  if (cfg.glm) await fetchGlmQuota(pid);
};
```

- [ ] **Step 2: Add host_permission to manifest.json**

Edit `extension/manifest.json`. Change `host_permissions` array (line 27-31) to include z.ai:

```json
"host_permissions": [
  "https://claude.ai/*",
  "https://api.deepseek.com/*",
  "https://platform.xiaomimimo.com/*",
  "https://api.z.ai/*"
],
```

- [ ] **Step 3: Add `'glm'` to receiver VALID_VENDORS**

Edit `native-host/quota-receiver.py:65`. Change:

```python
VALID_VENDORS = frozenset({'deepseek', 'mimo', 'glm'})
```

- [ ] **Step 4: Reload extension + re-grant host_permission**

In Chrome:
1. `chrome://extensions` → cc-quota-fetcher → **Reload**
2. **Click "Details"** on cc-quota-fetcher card
3. Scroll to **"Site access"** → ensure `https://api.z.ai/*` is set to **"On all sites"** OR explicitly **"Allow"** for that host
4. If a permission prompt appears at top of chrome window asking to allow api.z.ai, click **Allow**

- [ ] **Step 5: Fill the GLM key in popup**

Click cc-quota-fetcher icon → popup. Source the z.ai key from your local secrets and paste it into the GLM API Key field:

```bash
. ~/.zsh_secrets
printf '%s\n' "$ZAI_API_KEY"
```

Paste into the GLM field, click outside (blur to fire `change` event). Re-open popup to verify the field is non-empty.

- [ ] **Step 6: Verify fetch fires — chrome console + receiver log + cache file**

a. Chrome console: `chrome://extensions` → cc-quota-fetcher → **"service worker"** link → DevTools console. Within ~30s should see no exceptions; the alarm fires `tick()` which now ends with `fetchGlmQuota`.

b. Receiver log (last 5 entries should include `vendor-balance email=None` since `vendor-balance` messages carry no email):

```bash
tail -5 ~/.claude/cache/quota-receiver.log
```

Expected: at least one `recv: vendor-balance email=None` line within the last 30s (also true for DS / mimo, so look at fresh tail).

c. **Cache file written:**

```bash
ls -la ~/.claude/cache/vendor-glm-*.json
jq '.vendor, .data.level, (.data.limits | length)' ~/.claude/cache/vendor-glm-*.json
```

Expected output:
```
"glm"
"lite"
3
```

If `.status` file appears instead of `.json`, the fetch failed:

```bash
cat ~/.claude/cache/vendor-glm-*.status
```

Common failure modes:
- `HTTP 401` → API key wrong / missing / had `Bearer ` accidentally prepended
- `network` → host_permission not granted (re-do Step 4)
- No file at all → checkbox not checked (re-do Step 5) or `glm_api_key` empty in storage

- [ ] **Step 7: Commit**

```bash
cd ~/Desktop/projects/cc-quota-fetcher
git add extension/background.js extension/manifest.json native-host/quota-receiver.py
git commit -m "feat(fetcher): add GLM (z.ai) quota fetch via /api/monitor/usage/quota/limit

Polls z.ai Coding Plan quota endpoint on existing alarm tick, writes raw
limits[] array into vendor-glm-<pid>.json. Uses Authorization header WITHOUT
Bearer prefix (z.ai quirk). Adds api.z.ai to host_permissions and 'glm' to
receiver's VALID_VENDORS whitelist."
```

---

## Task 3: wrapper — RED_BOLD const + 2 helpers + global vars

**Repo:** `cc-statusline-widgets` (this repo)

**Files:**
- Modify: `scripts/wrapper.sh` (top constants, helper region around line 76, segment array region around line 83)

**Interfaces:**
- Consumes: existing `RED`, `BLUE`, `GREEN`, `YELLOW`, `GRAY`, `RST` constants
- Produces:
  - `RED_BOLD` const (`$'\033[1;38;5;160m'`)
  - `quota_pct_color <int>` → ANSI color escape string
  - `fmt_glm_countdown <reset_ms_or_empty>` → countdown string (`0m`, `Nm`, `NhNm`, `NdNh`)
  - `GLM_5H_PCT`, `GLM_W_PCT`, `GLM_LEVEL` global string vars (consumed by Task 5 widget-log block)

- [ ] **Step 1: Add `RED_BOLD` const next to `RED`**

Edit `scripts/wrapper.sh`. After the existing `RED=$'\033[38;5;160m'` line (line 12), add:

```bash
RED_BOLD=$'\033[1;38;5;160m'
```

- [ ] **Step 2: Add `quota_pct_color` helper next to `pct_color`**

After the existing `pct_color()` function (around line 81), add:

```bash
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
```

- [ ] **Step 3: Add `fmt_glm_countdown` helper**

Immediately after `quota_pct_color`, add:

```bash
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
```

- [ ] **Step 4: Add global vars for widget-log export**

In the segment array block (around line 83, near `S1_BG=() ; S1_TX=() ...`), add right before or after that line:

```bash
GLM_5H_PCT="" ; GLM_W_PCT="" ; GLM_LEVEL=""
```

- [ ] **Step 5: Quick smoke test the helpers in isolation**

```bash
cd ~/Desktop/projects/cc-statusline-widgets
bash -c 'source <(sed -n "1,90p" scripts/wrapper.sh); quota_pct_color 0; printf "GREEN\n"; quota_pct_color 50; printf "YELLOW\n"; quota_pct_color 95; printf "RED\n"; quota_pct_color 100; printf "RED_BOLD\n"'
```

Expected: four lines with ANSI escape sequences followed by the color name label. Visually each label should appear in its named color (terminal ANSI rendering).

Also test countdown:

```bash
bash -c 'source <(sed -n "1,90p" scripts/wrapper.sh); fmt_glm_countdown ""; echo; fmt_glm_countdown 0; echo; fmt_glm_countdown null; echo; fmt_glm_countdown $(( ($(date +%s) + 86400 * 7) * 1000 )); echo'
```

Expected output:
```
0m
0m
0m
6d23h
```

(Last value might be `7d0h` if rounded exactly; either is fine — sanity check the format.)

- [ ] **Step 6: Commit**

```bash
cd ~/Desktop/projects/cc-statusline-widgets
git add scripts/wrapper.sh
git commit -m "refactor(wrapper): add RED_BOLD const + quota_pct_color/fmt_glm_countdown helpers

Hoists the 5-stage quota color threshold (≥100/80/50/30/<30) and the
ms-epoch countdown formatter into reusable helpers, mirroring usage-color.sh
conventions. RED_BOLD distinguishes ≥100% (real overrun) from ≥80% (near).
Prep for upcoming GLM quota pill."
```

---

## Task 4: wrapper — fmt_glm_quota core function

**Repo:** `cc-statusline-widgets`

**Files:**
- Modify: `scripts/wrapper.sh` (new function, placed near `fmt_deepseek_balances` around line 419-463)

**Interfaces:**
- Consumes:
  - `~/.claude/cache/vendor-glm-<pid>.json` (from fetcher Task 2)
  - `~/.claude/cache/vendor-glm-<pid>.status` (error sentinel, optional)
  - `$ACTIVE_PID` (read from `~/.claude/cache/vendor-active-profile`, already populated by other fetcher vendors)
  - Helpers from Task 3 (`quota_pct_color`, `fmt_glm_countdown`)
  - Constants: `$BLUE`, `$RED`, `$RST`
- Produces:
  - stdout: pill segment text like `Lite: 0% 0m | 0% 6d23h` (ANSI-colored)
  - Side effect: sets `GLM_5H_PCT` / `GLM_W_PCT` / `GLM_LEVEL` global vars from Task 3
- Consumed by: Task 5 (`push_seg 2 "$WT_BG_GLM" "$(fmt_glm_quota)"`)

- [ ] **Step 1: Add `fmt_glm_quota` function**

Edit `scripts/wrapper.sh`. After `fmt_vendor_plan` (around line 500, before `usage_part=` block), add:

```bash
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
  IFS=$'\t' read -r fivehr_pct weekly_pct weekly_reset level <<<"$parsed"

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
```

- [ ] **Step 2: Mock-cache test of `fmt_glm_quota`**

Create a mock cache file under a tmp prefix and patch `QUOTA_CACHE_DIR` for a one-shot test:

```bash
cd ~/Desktop/projects/cc-statusline-widgets
mkdir -p /tmp/cc-glm-test
cat > /tmp/cc-glm-test/vendor-glm-deadbeef.json <<'JSON'
{"vendor":"glm","profile_id":"deadbeef","data":{"level":"lite","limits":[
  {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":0,"nextResetTime":1784434774979,"usageDetails":[]},
  {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":42},
  {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":17,"nextResetTime":1782447574976}
]}}
JSON

ACTIVE_PID="deadbeef" QUOTA_CACHE_DIR="/tmp/cc-glm-test" \
  bash -c '
    source <(sed -n "1,90p" scripts/wrapper.sh)
    QUOTA_CACHE_DIR="/tmp/cc-glm-test"
    ACTIVE_PID="deadbeef"
    '"$(sed -n "/^fmt_glm_quota() {/,/^}$/p" scripts/wrapper.sh)"'
    fmt_glm_quota
    echo
    echo "GLM_5H_PCT=$GLM_5H_PCT GLM_W_PCT=$GLM_W_PCT GLM_LEVEL=$GLM_LEVEL"
  '
```

Expected stdout (ANSI sequences elided): `Lite: 42% 0m | 17% Nd Nh` where N depends on current time (weekly reset is 2026-06-26).

Expected last line: `GLM_5H_PCT=42 GLM_W_PCT=17 GLM_LEVEL=lite`.

If the date math is past 2026-06-26 by the time the implementer runs this, edit the mock JSON `nextResetTime` to `$(date -v+7d +%s)000` first.

- [ ] **Step 3: Commit**

```bash
cd ~/Desktop/projects/cc-statusline-widgets
git add scripts/wrapper.sh
git commit -m "feat(wrapper): add fmt_glm_quota function for GLM Coding Plan pill

Parses ~/.claude/cache/vendor-glm-<pid>.json with primary
(type, unit, number) classification + nextResetTime fallback, renders
<Tier>: X% Nm | X% Nd Nh format with 5h rolling sentinel (0m)."
```

---

## Task 5: wrapper — line 2 push + widget-log + deploy + e2e verify

**Repo:** `cc-statusline-widgets`

**Files:**
- Modify: `scripts/wrapper.sh` (theme color top, line 2 push around line 537-538, widget-log around line 685-712)

**Interfaces:**
- Consumes: `fmt_glm_quota` (from Task 4), `$ACTIVE_PID`, theme constants
- Produces:
  - Statusline line 2 with GLM pill before DS pill
  - Widget-log JSONL with `glm_level`, `glm_5h_pct`, `glm_w_pct` fields

- [ ] **Step 1: Add `WT_BG_GLM` theme color**

Edit `scripts/wrapper.sh`. Near the existing `WT_BG_VENDOR` line (around line 54), add:

```bash
WT_BG_GLM=${WT_BG_GLM:-${VL_BG_GLM:-99}}
```

- [ ] **Step 2: Push GLM pill before DS pill on line 2**

Edit `scripts/wrapper.sh` around line 537-538. Find the existing block:

```bash
ds_part=$(fmt_deepseek_balances "DS" 2>/dev/null || echo "")
[[ -n "$ds_part" ]] && push_seg 2 "$WT_BG_VENDOR" "$ds_part"
```

Replace with:

```bash
glm_part=$(fmt_glm_quota 2>/dev/null || echo "")
[[ -n "$glm_part" ]] && push_seg 2 "$WT_BG_GLM" "$glm_part"

ds_part=$(fmt_deepseek_balances "DS" 2>/dev/null || echo "")
[[ -n "$ds_part" ]] && push_seg 2 "$WT_BG_VENDOR" "$ds_part"
```

- [ ] **Step 3: Add widget-log fields**

Edit `scripts/wrapper.sh` widget-log block (around line 685-710). After the existing `--arg skill "$skill_name" \` line (or any visually similar location inside the `jq -nc` block), add three lines:

```bash
    --arg glm_level   "${GLM_LEVEL:-}" \
    --arg glm_5h_pct  "${GLM_5H_PCT:-}" \
    --arg glm_w_pct   "${GLM_W_PCT:-}" \
```

Make sure these are inserted BEFORE the closing `'$ARGS.named' \` line.

- [ ] **Step 4: Deploy to runtime copy**

```bash
cd ~/Desktop/projects/cc-statusline-widgets
bash scripts/install.sh
```

OR single-file fast path:

```bash
cp scripts/wrapper.sh ~/.claude/scripts/cc-statusline/wrapper.sh
```

- [ ] **Step 5: e2e verify against runtime copy (NOT repo file)**

```bash
echo '{"model":{"display_name":"sonnet"},"context_window":{"used_percentage":0,"context_window_size":200000,"current_usage":{}}}' \
  | bash ~/.claude/scripts/cc-statusline/wrapper.sh
```

Expected: line 2 contains `Lite: 0% 0m | 0% NdNh` (real percentages depend on your z.ai usage at that moment) in a purple-ish pill **immediately before** the DeepSeek pill.

If GLM pill is absent:

```bash
ls -la ~/.claude/cache/vendor-glm-*.json ~/.claude/cache/vendor-glm-*.status 2>/dev/null
ACTIVE_PID=$(cat ~/.claude/cache/vendor-active-profile)
echo "ACTIVE_PID=$ACTIVE_PID"
jq '.data.level, (.data.limits | length)' ~/.claude/cache/vendor-glm-*.json
```

Common failures:
- `.json` missing → fetcher (Task 2) not populating cache, debug there first
- `.status` present → fetcher returned error; cat the file for reason
- `.json` exists but pill missing → check `QUOTA_CACHE_DIR` env in runtime copy matches `~/.claude/cache`; also check `ACTIVE_PID` matches the pid suffix on the cache file

- [ ] **Step 6: Verify widget-log schema sync**

Wait at least 5 minutes from any previous wrapper invocation (5min throttle), then run wrapper once:

```bash
echo '{"model":{"display_name":"sonnet"},"session_id":"test-glm","context_window":{"used_percentage":0,"context_window_size":200000,"current_usage":{}}}' \
  | bash ~/.claude/scripts/cc-statusline/wrapper.sh > /dev/null

tail -1 ~/.claude/projects/widget-log/$(date +%Y-%m).jsonl \
  | jq '{glm_level, glm_5h_pct, glm_w_pct}'
```

Expected:
```json
{
  "glm_level": "lite",
  "glm_5h_pct": "0",
  "glm_w_pct": "0"
}
```

(Percentages will be empty strings if no GLM cache file exists or if `fmt_glm_quota` returned early.)

- [ ] **Step 7: Commit**

```bash
cd ~/Desktop/projects/cc-statusline-widgets
git add scripts/wrapper.sh
git commit -m "feat(wrapper): wire GLM Coding Plan quota pill on line 2 before DS

Renders <Tier>: X% Nm | X% Nd Nh format matching Anthropic pill style,
in front of the DeepSeek balance pill. Adds WT_BG_GLM theme color and
glm_level / glm_5h_pct / glm_w_pct fields to the widget-log snapshot."
```

---

## Self-Review

Spec coverage check against `docs/superpowers/specs/2026-06-19-glm-widget-design.md`:

- ✅ z.ai API endpoint + auth (Task 2 Step 1) — `Authorization` without Bearer + `Accept-Language` covered
- ✅ Three `limits[]` classification rules — primary `(type, unit, number)` jq selector + nextResetTime fallback both in Task 4 Step 1
- ✅ Pill format `<Tier>: X% 0m | X% Nd Nh` — Task 4 Step 1, verified by Task 4 Step 2 mock test
- ✅ Tier label from `data.level` with auto-capitalize — Task 4 Step 1 `awk toupper/tolower` substr
- ✅ 5-stage threshold + RED_BOLD — Task 3 Step 1 & 2
- ✅ chrome host_permission re-grant — Task 2 Step 4 explicit step
- ✅ Fetcher dry-run debug steps — Task 2 Step 6 (chrome console / receiver log / cache file)
- ✅ Pill placement before DS — Task 5 Step 2 with exact block replacement
- ✅ widget-log schema sync — Task 5 Step 3 three new fields
- ✅ Runtime deploy + verify on runtime copy — Task 5 Step 4-5
- ✅ profile_id共用約定 — implicit via `ACTIVE_PID` fallback in Task 4 fmt_glm_quota

Placeholder scan: no TBD / TODO / "implement later" / "similar to Task N" without code repeat.

Type consistency check:
- `GLM_5H_PCT` / `GLM_W_PCT` / `GLM_LEVEL` — declared Task 3 Step 4, assigned Task 4 Step 1, read Task 5 Step 3 ✓
- `fmt_glm_quota` — defined Task 4 Step 1, called Task 5 Step 2 ✓
- `quota_pct_color` / `fmt_glm_countdown` — defined Task 3 Step 2-3, called Task 4 Step 1 ✓
- `WT_BG_GLM` — defined Task 5 Step 1, used Task 5 Step 2 ✓
- `glm_api_key` storage key — written Task 1 Step 2, read Task 2 Step 1 (`getGlmApiKey`) ✓
- `vendor_enabled.glm` boolean — written Task 1 Step 2, read Task 2 Step 1 (`tick()` gating) ✓

All cross-task references resolve. Plan is internally consistent.
