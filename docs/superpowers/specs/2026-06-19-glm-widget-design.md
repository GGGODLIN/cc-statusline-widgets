# GLM Coding Plan 用量 widget — Design

**Date**: 2026-06-19
**Owner repo**: `cc-statusline-widgets`（widget design 為核心，跨 repo 改動分工列在後面）
**Sister repo**: `cc-quota-fetcher`（fetcher 端，必須同步動）

## 動機

User 剛訂閱 z.ai Coding Plan（GLM Coding Lite），希望在 statusline line 2 顯示 GLM 訂閱用量，**放在 DeepSeek pill 前面**。

現況 line 2 順序：

```
[Anthropic Account A 5h%/7d% pill] [Anthropic Account B 5h%/7d% pill] [DS 餘額 pill]
```

目標：

```
[Anthropic ...] [Anthropic ...] [GLM 5h%/Weekly% pill] [DS 餘額 pill]
```

## z.ai API schema（實測 2026-06-19）

### `GET https://api.z.ai/api/monitor/usage/quota/limit`

**Auth**: `Authorization: <token>` — ⚠️ **無 `Bearer ` prefix**（z.ai 踩坑點，跟 DeepSeek 不同）。Token = z.ai 訂閱配給 CC 用的 `ANTHROPIC_AUTH_TOKEN`（user 本機已存 `ZAI_API_KEY` 在 `~/.zsh_secrets`）。

**真實 response**（user 帳號實測，Lite tier 全 0%）：

```json
{
  "code": 200,
  "data": {
    "level": "lite",
    "limits": [
      {
        "type": "TIME_LIMIT",
        "unit": 5, "number": 1,
        "usage": 100, "currentValue": 0, "remaining": 100,
        "percentage": 0,
        "nextResetTime": 1784434774979,
        "usageDetails": [
          { "modelCode": "search-prime", "usage": 0 },
          { "modelCode": "web-reader", "usage": 0 },
          { "modelCode": "zread", "usage": 0 }
        ]
      },
      { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 0 },
      {
        "type": "TOKENS_LIMIT",
        "unit": 6, "number": 1,
        "percentage": 0,
        "nextResetTime": 1782447574976
      }
    ]
  }
}
```

### `limits[]` 三項對照

**Primary 對照**（`(type, unit, number)` 三鍵，verified via opencode-glm-quota source）：

| `(type, unit, number)` | 意義 | 有 `nextResetTime`? | 顯示 |
|---|---|---|---|
| `TIME_LIMIT, 5, 1` | Monthly MCP tool quota（search-prime / web-reader / zread） | ✅ ~30d | **不顯示**（pill 太擠，CC 使用情境不太碰） |
| `TOKENS_LIMIT, 3, 5` | **5h rolling tokens** | ❌（z.ai 自己沒給） | 主段：`X% 0m`（沿用 Anthropic `fmt_diff(0)` 慣例） |
| `TOKENS_LIMIT, 6, 1` | **Weekly tokens**（FAQ「7-day cycle」） | ✅ ~7d | 副段：`X% Nd Nh` |

**Fallback 對照**（z.ai 將來改 unit 編號 wrapper 不 silently 變空）：

按 `nextResetTime` 距現在的時間差推斷：

| 條件 | 推斷類別 |
|---|---|
| `type=TOKENS_LIMIT` 且無 `nextResetTime` | **5h rolling tokens** |
| `type=TOKENS_LIMIT` 且 `5d < (reset - now) < 9d` | **Weekly tokens** |
| `type=TIME_LIMIT` 且 `25d < (reset - now) < 35d` | **Monthly MCP** |
| 其他 | unknown，silently skip |

實作時 primary 先試（精確），missed 才走 fallback。

⚠️ **5h rolling 約定**：z.ai 不給 5h `nextResetTime`，沿用 `usage-color.sh` 的 `fmt_diff(0)` → `0m` 慣例。視覺對稱維持 `X% 0m | X% Nd Nh m`。

### 其他兩條 endpoint

- `/api/monitor/usage/model-usage` — hourly token / call series（無 %），本 widget **不接**
- `/api/monitor/usage/tool-usage` — hourly MCP tool series（無 %），本 widget **不接**

將來想顯示 24h cost / MCP 用量再加 endpoint。

## Display 設計

### Pill 格式

仿 Anthropic pill `Max: 19% 3h59m | 67% 22h59m` 的 `<Tier>: <5h%> <5h-countdown> | <7d%> <7d-countdown>` 雙段結構：

```
Lite: 0% 0m | 0% 6d23h
```

- `Lite` 從 response `data.level` 大寫得來（`lite` → `Lite`）；user 換 tier (Pro/Max) wrapper 自動感應、不寫死
- 第一段 `0% 0m` — 5h rolling 無 reset，countdown 走 `fmt_diff(0)` → `0m`（沿用 Anthropic 慣例）
- 第二段 `0% 6d23h` — weekly % + 真實倒數
- Weekly 段 conditional：如果 response 沒 weekly 項（unlimited weekly 那批 user）只顯示 `Lite: 0% 0m`，整個 ` | ...` 段省略

### 顏色 threshold（per-segment）

對齊 `usage-color.sh` 既有規則（讓 GLM pill 視覺一致）：

| utilization (%) | 顏色 |
|---|---|
| ≥100 | RED_BOLD |
| ≥80 | RED |
| ≥50 | YELLOW |
| ≥30 | BLUE |
| <30 | GREEN |

兩段獨立判色（Anthropic pill 也是兩段獨立）。Tier label（`Lite:`）走 `BLUE` 同其他 label 風格。

### Tier 切換

User 隨時可能換 tier。設計刻意**不**在任何地方 hard-code tier name 或 prompt cap：

- `level` field API 直接給、wrapper 大寫即可
- threshold 是 percentage-based、跟 tier 絕對額度無關
- popup 不要 tier dropdown

### 不顯示的東西

- Monthly MCP quota — CC 使用者不太碰 search-prime / web-reader / zread，加進 pill 沒淨價值。將來想要時加副欄
- z.ai API key — 全程不 leak 進顯示
- `usageDetails` 細項 — 同上

## 系統架構分工

### `cc-quota-fetcher`（fetcher 端，必須先動）

**`extension/background.js`**

新增 const：

```js
const GLM_QUOTA_URL = 'https://api.z.ai/api/monitor/usage/quota/limit';
```

新增函式 `fetchGlmQuota(pid)`，仿 `fetchDeepSeekBalance` 但：
- Auth header `Authorization: ${apiKey}`（無 Bearer prefix）
- 多帶 `'Accept-Language': 'en-US,en'`、`'Content-Type': 'application/json'`
- `credentials: 'omit'`（純 API、不混 cookie）
- 成功時 send `{ type: 'vendor-balance', vendor: 'glm', data: { level, limits } }` — 整個 `limits[]` 原樣傳；wrapper 端再解析

`VENDOR_DEFAULTS`：

```js
const VENDOR_DEFAULTS = { deepseek: true, mimo: true, glm: true };
```

`tick()` 末段：

```js
if (cfg.glm) await fetchGlmQuota(pid);
```

**`extension/popup.html` + `popup.js`**

加 GLM checkbox + API key 輸入欄（仿 DeepSeek 那組）：

- checkbox `id="glm"` (default checked)
- text input `id="glm_api_key"`（saved as `chrome.storage.local.glm_api_key`）
- 兩者一起塞進 vendor table

base URL 暫**寫死** `api.z.ai`。將來 user 切到 `open.bigmodel.cn` 再加 selector。

**`extension/manifest.json`**

`host_permissions` 加：

```
"https://api.z.ai/*"
```

⚠️ **新增 host_permissions 後 Chrome 必須 user 手動 re-grant**：reload extension 後 `chrome://extensions` 頁面對 cc-quota-fetcher 會出現「Allow」prompt，user 沒點 fetcher 對 api.z.ai 永遠 silent fail、wrapper 端不會出現 GLM pill 也不會出現 status pill（背景 `fetch()` reject 在 onbeforerequest）。部署段必須提醒。

**`native-host/quota-receiver.py`**

```python
VALID_VENDORS = frozenset({'deepseek', 'mimo', 'glm'})
```

不用改其他 — schema 已經是「vendor-balance with data 任意 JSON」，原樣寫進 `~/.claude/cache/vendor-glm-<pid>.json`。

### profile_id 共用約定

`fmt_glm_quota` 從 `~/.claude/cache/vendor-active-profile` 拿 `ACTIVE_PID`、若空則用 `ls vendor-glm-*.json` fallback。**前提**：GLM cache 跟 DS / mimo cache 共用同一個 cc-quota-fetcher chrome extension 生出的 `profile_id`（同 extension `chrome.storage.local.profile_id` 一個 UUID slice 8 hex）。User 沒裝多 chrome profile 多帳號訂閱情境，這條約定夠用。多 profile 場景請 punt 給 future work。

### `cc-statusline-widgets`（wrapper 端）

**`scripts/wrapper.sh`**

新增主題色（line ~54 周遭，靠近 `WT_BG_VENDOR`）：

```bash
WT_BG_GLM=${WT_BG_GLM:-${VL_BG_GLM:-99}}   # 紫色系，跟 DS 70,80,110 azure 區隔
```

**新增 `RED_BOLD` const**（wrapper.sh top line ~12 周遭，跟 `RED` 並列），讓 `≥100%` 真的撞滿時跟 `≥80%` 視覺有別：

```bash
RED_BOLD=$'\033[1;38;5;160m'
```

**新增全域 helper `quota_pct_color`**（hoist 出來不要 inline 在 `fmt_glm_quota` 內 — 將來 Anthropic / 其他 quota pill 都可 reuse）。

⚠️ **為何不改既有 `pct_color` 而新增一個 helper**：wrapper 既有 `pct_color`（line ~76）是 context bar 進度警示用的三段 (75%/50%/<50%)，視覺語意是「上下文用了多少、漸進變紅」；GLM / Anthropic quota pill 對齊 `usage-color.sh:color_for` 的五段 (100%/80%/50%/30%/<30%)、含「真的滿了 vs 將近滿 vs 大半 vs 過半 vs 安全」分層警示。兩者不同職責、不要硬合併否則破壞 context bar 既有色。

放在現有 `pct_color` 旁邊 (line ~76 周遭)：

```bash
quota_pct_color() {  # 五段顏色 (對齊 usage-color.sh color_for)
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

**新增 helper `fmt_glm_countdown`**（共用 `fmt_diff` 寫法，沿用 Anthropic 慣例：拿不到 reset 印 `0m`）：

```bash
fmt_glm_countdown() {  # $1=reset_ms（空 / null / 0 → 0m）
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

**Global var 給 widget-log 用**（fmt 函式 export 給末段 log 引用，避免重打 jq parse）。在 wrapper top-of-file 跟 `S1_BG=()` 等並列宣告：

```bash
GLM_5H_PCT=""
GLM_W_PCT=""
GLM_LEVEL=""
```

**新增函式 `fmt_glm_quota`**（仿 `fmt_deepseek_balances`、`fmt_vendor_plan`）：

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

  # 一次 jq pass：吐出三行 — fivehr_pct \t weekly_pct \t weekly_reset \t level
  # 規則：primary (type,unit,number) 三鍵 → 失手才走 nextResetTime 時間差 fallback
  local parsed
  parsed=$(jq -r '
    .data as $d
    | ($d.level // "glm") as $level
    | ($d.limits // []) as $L
    | (now * 1000) as $now_ms
    | (
        # 5h primary: type=TOKENS_LIMIT, unit=3, number=5
        ([$L[] | select(.type=="TOKENS_LIMIT" and .unit==3 and .number==5)] | first)
        // ([$L[] | select(.type=="TOKENS_LIMIT" and (.nextResetTime // null) == null)] | first)
      ) as $h5
    | (
        # weekly primary: type=TOKENS_LIMIT, unit=6, number=1
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

  # export for widget-log
  GLM_5H_PCT="$fivehr_pct"
  GLM_W_PCT="$weekly_pct"
  GLM_LEVEL="$level"

  # tier label: lite → Lite, pro → Pro, max → Max
  local label
  label="$(printf '%s' "$level" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')"

  local out="${BLUE}${label}: ${RST}"

  # segment 1: 5h — % + countdown (rolling → 0m)
  if [[ -n "$fivehr_pct" ]]; then
    local p1_int p1_color cd1
    p1_int=$(awk -v p="$fivehr_pct" 'BEGIN { printf "%d", p }')
    p1_color=$(quota_pct_color "$p1_int")
    cd1=$(fmt_glm_countdown "")  # 5h 永遠沒 reset → 0m
    out="${out}${p1_color}${p1_int}%${RST}${BLUE} ${cd1}${RST}"
  fi

  # segment 2: weekly — % + countdown
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

**Pill push（line 2，DS 前面）**

```bash
glm_part=$(fmt_glm_quota 2>/dev/null || echo "")
[[ -n "$glm_part" ]] && push_seg 2 "$WT_BG_GLM" "$glm_part"

ds_part=$(fmt_deepseek_balances "DS" 2>/dev/null || echo "")
[[ -n "$ds_part" ]] && push_seg 2 "$WT_BG_VENDOR" "$ds_part"
```

放在現有 DS push_seg **之前**。

**Widget-log schema**

`wrapper.sh` 末段 widget-log 區（line ~685）加三欄。值從 `fmt_glm_quota` 已 export 的 global var 取（不再打第二次 jq）：

```bash
--arg glm_level   "${GLM_LEVEL:-}" \
--arg glm_5h_pct  "${GLM_5H_PCT:-}" \
--arg glm_w_pct   "${GLM_W_PCT:-}" \
```

### 主題檔（themes/*.conf）

加可選變數讓 theme override：

```
# themes/claude-coral.conf 等
VL_BG_GLM=99
```

不加也 OK，wrapper 預設 fallback。

## Cache schema

`~/.claude/cache/vendor-glm-<pid>.json` — fetcher 端寫入，wrapper 端讀：

```json
{
  "vendor": "glm",
  "profile_id": "4a6f8fb4",
  "fetched_at": "13:45:12",
  "data": {
    "level": "lite",
    "limits": [/* z.ai response 原樣 */]
  }
}
```

Error status：`~/.claude/cache/vendor-glm-<pid>.status`，格式同 DS / Anthropic（`<HH:MM:SS>\t<reason>`）。

## 部署 / verify

按 `CLAUDE.md` 指示：

1. **fetcher 端 reload + 補權限**：`extension/` 改完後在 Chrome `chrome://extensions` 對 cc-quota-fetcher 點「Reload」。**新加的 `https://api.z.ai/*` host_permission 可能需要手動點「Allow」** — 進 cc-quota-fetcher 的「Details」→ 「Site access」確認 api.z.ai 是 Allow，不是 Ask。
2. **popup 填 API key + 勾 GLM checkbox**：點 cc-quota-fetcher icon 開 popup → 填 z.ai API key (=`ZAI_API_KEY` 也就是 `ANTHROPIC_AUTH_TOKEN`) → 勾 `GLM` checkbox → Save。
3. **fetcher 端 dry-run**：
   - chrome console 看 background.js log：`chrome://extensions` → cc-quota-fetcher 「service worker」連結，console 該有 `fetchGlmQuota` 30s 一次的 log
   - 看 receiver log：`tail -20 ~/.claude/cache/quota-receiver.log` 該有 `recv: vendor-balance email=None` (GLM 是 vendor-balance type)
   - 看 cache：

     ```bash
     ls -la ~/.claude/cache/vendor-glm-*.json
     jq '.data.level, (.data.limits | length)' ~/.claude/cache/vendor-glm-*.json
     ```

     沒有就先排查 fetcher 端、不要往 wrapper 找。常見 fail：API key 沒填 / 沒勾 GLM checkbox / host_permission 沒 Allow。
4. **wrapper 端部署**：`bash scripts/install.sh`（或只 `cp scripts/wrapper.sh ~/.claude/scripts/cc-statusline/wrapper.sh`）
5. **verify 對 runtime 副本**（不是 repo 檔）：

   ```bash
   echo '{"model":{"display_name":"sonnet"}}' | bash ~/.claude/scripts/cc-statusline/wrapper.sh
   ```

   觀察 line 2 是否出現 `Lite: 0% 0m | 0% 6d23h` 在 DS 前面。
6. **widget-log 寫入**：5min throttle、跑幾次 wrapper 後檢查最新一行有 `glm_level` / `glm_5h_pct` / `glm_w_pct` 欄位（`tail -1 ~/.claude/projects/widget-log/$(date +%Y-%m).jsonl | jq '{glm_level,glm_5h_pct,glm_w_pct}'`）。

## 兼容性 / Future work

- **base URL 切換**：若將來 user 用 `open.bigmodel.cn` (CN-issued API key)，popup 加 base URL 選擇器，cache JSON 加 `base_url` 欄
- **Monthly MCP**：將來想看 MCP 用量加副欄 `M Y%` 或直接顯示 `usageDetails` count
- **5h reset 推算**：z.ai 不給 5h reset 是已知，將來若官方補上、wrapper 自動有 countdown（schema 已預備）
- **未知 limit type**：wrapper 對未認得的 `(type, unit, number)` 組合 silently skip，不會破壞 pill

## YAGNI 不做

- ❌ Tier dropdown / hard-code prompt cap — `level` field API 已給
- ❌ z.ai vs bigmodel.cn 切換 UI — 你現在沒設 BIGMODEL_API_KEY，需要時再加
- ❌ Monthly MCP pill — 邊際價值低、line 2 已擠
- ❌ Model-usage / tool-usage endpoint — 是時間 series 不是 %，pill 塞不下
- ❌ 5h reset 時間臆造 — z.ai 不給 `nextResetTime` 就走 Anthropic `fmt_diff(0)` 慣例印 `0m`，不假裝估算「下一波 5h 截止」
- ❌ Cost estimation — z.ai Coding Plan 是訂閱不是 metered，cost % 沒意義
