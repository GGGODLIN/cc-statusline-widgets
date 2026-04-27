# Reverse-engineering [sirmalloc/ccstatusline](https://github.com/sirmalloc/ccstatusline)

**Date**: 2026-04-27
**Goal**: 抽出自製 wrapper 需要的核心 logic — 特別是 transcript parsing / token / pricing — 評估 bash 可行性。

## TL;DR

**CC 給 statusLine.command 的 stdin JSON 已含算好的 cost / context / rate_limits**。ccstatusline 大部分時間只是 jq-style 取值。**transcript parse 只是 fallback**。

工程量比預期小 ~3x。bash + jq 130-170 行可 cover 主路徑。

## CC stdin Schema（從 `src/types/StatusJSON.ts` 抓）

```typescript
{
  hook_event_name?: string,
  session_id?: string,
  transcript_path?: string,
  cwd?: string,
  model?: string | { id?: string, display_name?: string },
  workspace?: { current_dir?: string, project_dir?: string },
  version?: string,
  output_style?: { name?: string },
  cost?: {
    total_cost_usd?: number,           // SessionCost 直接拿
    total_duration_ms?: number,
    total_api_duration_ms?: number,
    total_lines_added?: number,
    total_lines_removed?: number
  },
  context_window?: {
    context_window_size?: number,
    total_input_tokens?: number,
    total_output_tokens?: number,
    current_usage?: number | {
      input_tokens?, output_tokens?,
      cache_creation_input_tokens?,
      cache_read_input_tokens?
    },
    used_percentage?: number,           // ContextBar 直接拿
    remaining_percentage?: number
  },
  vim?: { mode?: string },
  worktree?: { name?, path?, branch?, original_cwd?, original_branch? },
  rate_limits?: {
    five_hour?: { used_percentage?, resets_at? },   // quota 從這拿（不用打 oauth API）
    seven_day?: { used_percentage?, resets_at? }
  }
}
```

## 各 widget 資料來源

| Widget | 來源 | 算法複雜度 |
|---|---|---|
| `model` | `data.model.display_name` 或 `data.model.id` | 🟢 jq 1 行 |
| `session-clock` | session 起始時間（從 transcript 第一行 timestamp，或自己 track） | 🟢 jq + date |
| `git-branch` / `ahead-behind` | git command（cwd 從 stdin） | 🟢 git 5-30ms |
| `free-memory` | `vm_stat` | 🟢 vm_stat + awk 5-15ms |
| **`session-cost`** | `data.cost.total_cost_usd` | 🟢 **jq 1 行 — CC 已算好** |
| **`context-bar`** | `data.context_window.used_percentage` + `current_usage` | 🟢 **jq 取值 + 進度條** |
| **`tokens-total`** | `data.context_window.current_usage` 累加 input+output+cache_creation+cache_read | 🟢 jq 加總 |
| `quota` (5h/weekly) | `data.rate_limits.five_hour.used_percentage` 跟 `seven_day` | 🟢 **jq + 不用打 API**（cc-quota-fetcher 仍然有用因為 schema 細節更多） |
| `skills` | hook state（`--hook` 模式更新） | 🟡 看 src/utils/skills.ts，需要 reverse |

## Token 累加（fallback only）

`src/utils/jsonl-metrics.ts` 的 `getTokenMetrics()` — 主邏輯：

```
for each line in transcript jsonl:
  data = JSON.parse(line)
  if data.message?.usage:
    parsedEntries.push(data)

# Streaming-aware filter
if 任何 entry 有 stop_reason field:
  entries_to_count = filter entries where stop_reason 為 truthy 或 (null 且 是最後一個)
else:
  entries_to_count = parsedEntries

for data in entries_to_count:
  inputTokens   += usage.input_tokens || 0
  outputTokens  += usage.output_tokens || 0
  cachedTokens  += (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0)

# Context length = 最後一個 main chain (isSidechain != true) 且非 isApiErrorMessage 的 entry
contextLength = lastMainChain.usage.input_tokens
              + lastMainChain.usage.cache_read_input_tokens
              + lastMainChain.usage.cache_creation_input_tokens

totalTokens = inputTokens + outputTokens + cachedTokens
```

**Bash 實作可行性**：用 jq + bash 變數累加，30-50 行。**只在 stdin context_window 缺欄位時才需跑**。

## Pricing tier — 完全不用！

**SessionCost.ts** 從頭到尾沒 hardcode pricing。直接讀 `data.cost.total_cost_usd`。

**含意**：CC 自己內部已算 cost（用什麼 pricing tier 邏輯都封在 CC，ccstatusline 不管）。bash wrapper 也不用管。

這層成本 **0**——之前我估「pricing tier 寫 bash 累」是錯的。

## Skills widget（複雜度待評估）

`src/widgets/Skills.tsx` 是 React/Ink 終端框架。`src/utils/skills.ts` 處理 hook state read/write。

**要不要 port 看 user 用 skills widget 多重要**。如果不重要，wrapper 第一版可以不做。

## 結論：bash 可行性確認

✅ **bash + jq 可行**
✅ 130-170 行主路徑（不含 fallback）
✅ 200-270 行（含 transcript parse fallback）
✅ Cold start 預估 30-80ms（vs ccstatusline 430ms，**~5-10x 提速**）
✅ 1Hz refreshInterval CPU 估 3-8% 一核（可接受）

⚠️ **不確定**：
- Skills widget logic 複雜度（如果要做的話）
- ccstatusline 的 `--hook` state 機制（PreToolUse / UserPromptSubmit 寫了什麼）

## 下一步

→ Phase 2 Decision: **語言選 bash**（不需 Go binary，工程量沒大到值得編譯式）
→ Phase 3: 實作 wrapper + daemon

## 來源檔（cloned to `/tmp/ccsl/`）

- `src/types/StatusJSON.ts` — stdin schema
- `src/utils/jsonl-metrics.ts` — `getTokenMetrics` 算 token / contextLength
- `src/utils/context-window.ts` — `getContextWindowMetrics` 從 stdin 取 context
- `src/widgets/SessionCost.ts` — 純 read `data.cost.total_cost_usd`
- `src/widgets/ContextBar.ts` — 主讀 stdin context_window，token metrics 為 fallback
- `src/widgets/TokensTotal.ts` — 用 tokenMetrics.totalTokens
- `src/utils/skills.ts` + `src/widgets/Skills.tsx` — Skills hook state（待評估）
