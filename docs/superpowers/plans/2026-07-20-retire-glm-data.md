# GLM Data Retirement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 停止 GLM statusline 顯示、widget-log 新欄位與背景輪詢，同時保留全部 GLM 基礎建設供未來復用。

**Architecture:** `cc-statusline-widgets` 只解除 formatter 的顯示與記錄接線，不刪除 formatter 本身；`cc-quota-fetcher` 不改 source，而是使用現有 vendor 開關將 `vendor_enabled.glm` 設為 false，並透過 `vendor-clear` 清除快取。runtime 採精確修改，保留目前兩行非 GLM 差異。

**Tech Stack:** Bash、jq、Chrome extension storage、Python native messaging receiver

## Global Constraints

- 保留 `fmt_glm_quota()`、GLM helper、色彩設定、抓取函式、Chrome UI、host permission 與 receiver 支援。
- 不刪除既有 widget-log 歷史。
- 不修改其他 vendor 的顯示、抓取或快取。
- 不以 repo source 全檔覆蓋 runtime，避免移除目前兩行非 GLM 差異。
- 所有 runtime 行為驗證都對 `~/.claude/scripts/cc-statusline/wrapper.sh` 執行。

---

### Task 1: 解除 GLM 顯示與記錄接線

**Files:**
- Modify: `scripts/wrapper.sh:664-667`
- Modify: `scripts/wrapper.sh:831-833`

**Interfaces:**
- Consumes: `fmt_glm_quota()` 與 `GLM_*` 暫存變數的既有定義。
- Produces: 不再呼叫 GLM formatter、也不再把 `glm_*` 傳入 `$ARGS.named` 的 wrapper source。

- [ ] **Step 1: 執行變更前反向斷言**

Run:

```bash
! grep -qF 'fmt_glm_quota 2>/dev/null' scripts/wrapper.sh
```

Expected: FAIL，因目前仍有 GLM 顯示接線。

Run:

```bash
! grep -qF -- '--arg glm_level' scripts/wrapper.sh
```

Expected: FAIL，因目前仍有 GLM widget-log 接線。

- [ ] **Step 2: 移除顯示接線**

從 `scripts/wrapper.sh` 刪除：

```bash
GLM_PILL_OUT=""
GLM_PILL_BG=""
fmt_glm_quota 2>/dev/null
[[ -n "$GLM_PILL_OUT" ]] && push_seg 2 "${GLM_PILL_BG:-$WT_BG_GLM}" "$GLM_PILL_OUT"
```

- [ ] **Step 3: 移除 widget-log 接線**

從 `scripts/wrapper.sh` 刪除：

```bash
    --arg glm_level   "${GLM_LEVEL:-}" \
    --arg glm_5h_pct  "${GLM_5H_PCT:-}" \
    --arg glm_w_pct   "${GLM_W_PCT:-}" \
```

- [ ] **Step 4: 驗證 source 接線已移除且基礎建設仍在**

Run:

```bash
bash -n scripts/wrapper.sh && \
! grep -qF 'fmt_glm_quota 2>/dev/null' scripts/wrapper.sh && \
! grep -qF -- '--arg glm_level' scripts/wrapper.sh && \
grep -qF 'fmt_glm_quota()' scripts/wrapper.sh && \
grep -qF 'fmt_glm_countdown()' scripts/wrapper.sh && \
grep -qF 'WT_BG_GLM=' scripts/wrapper.sh
```

Expected: exit 0。

- [ ] **Step 5: Commit source 變更與實作計畫**

```bash
git add scripts/wrapper.sh docs/superpowers/plans/2026-07-20-retire-glm-data.md
git commit -m "fix(wrapper): retire GLM data paths"
```

### Task 2: 精確部署到 runtime

**Files:**
- Modify: `~/.claude/scripts/cc-statusline/wrapper.sh:666-669`
- Modify: `~/.claude/scripts/cc-statusline/wrapper.sh:833-835`

**Interfaces:**
- Consumes: Task 1 已完成的 source 變更。
- Produces: 真正由 Claude Code 執行、但保留原有非 GLM 差異的 runtime wrapper。

- [ ] **Step 1: 保存並檢查部署前差異**

Run:

```bash
diff -u scripts/wrapper.sh ~/.claude/scripts/cc-statusline/wrapper.sh || true
```

Expected: 包含 runtime 既有的兩行非 GLM model cache 寫入，以及尚未部署的 GLM 刪除差異。

- [ ] **Step 2: 對 runtime 做與 source 相同的精確刪除**

從 runtime 副本刪除 GLM 顯示的四行接線與 widget-log 的三行 `--arg glm_*`，不修改其他行。

- [ ] **Step 3: 驗證 runtime 語法與保留項目**

Run:

```bash
bash -n ~/.claude/scripts/cc-statusline/wrapper.sh && \
! grep -qF 'fmt_glm_quota 2>/dev/null' ~/.claude/scripts/cc-statusline/wrapper.sh && \
! grep -qF -- '--arg glm_level' ~/.claude/scripts/cc-statusline/wrapper.sh && \
grep -qF 'fmt_glm_quota()' ~/.claude/scripts/cc-statusline/wrapper.sh && \
grep -qF 'fmt_glm_countdown()' ~/.claude/scripts/cc-statusline/wrapper.sh && \
grep -qF 'WT_BG_GLM=' ~/.claude/scripts/cc-statusline/wrapper.sh
```

Expected: exit 0。

- [ ] **Step 4: 用真實 runtime 輸入驗證輸出**

Run:

```bash
printf '%s' '{"workspace":{"current_dir":"/Users/linhancheng/Desktop/projects/cc-statusline-widgets"},"model":{"display_name":"Claude"},"session_id":"glm-retirement-check"}' | bash ~/.claude/scripts/cc-statusline/wrapper.sh | tee /tmp/cc-statusline-glm-retirement.out
! grep -q 'GLM' /tmp/cc-statusline-glm-retirement.out
```

Expected: wrapper exit 0，輸出中沒有 `GLM`。

### Task 3: 停止 GLM 輪詢並清除快取

**Files:**
- Runtime state: Chrome extension `vendor_enabled.glm`
- Runtime cache: `~/.claude/cache/vendor-glm-*`

**Interfaces:**
- Consumes: `cc-quota-fetcher` popup 的 `vendor-disable` 訊息與 native receiver 的 `vendor-clear` 實作。
- Produces: `vendor_enabled.glm=false`，GLM 快取清除，後續 alarm tick 跳過 `fetchGlmQuota()`。

- [ ] **Step 1: 記錄停用前快取狀態**

Run:

```bash
find ~/.claude/cache -maxdepth 1 -type f -name 'vendor-glm-*' -print
```

Expected: 至少列出目前的 GLM status 快取。

- [ ] **Step 2: 使用已安裝 extension 的 popup 取消勾選 GLM**

在 popup 將 `glm` checkbox 設為未勾選。此動作會依現有程式執行：

```js
cfg.glm = false;
await chrome.storage.local.set({ vendor_enabled: cfg });
chrome.runtime.sendMessage({ type: 'vendor-disable', vendor: 'glm' });
```

Expected: popup 顯示 GLM 未勾選，background 收到 `vendor-disable`。

- [ ] **Step 3: 確認快取已由既有清理路徑移除**

Run:

```bash
! find ~/.claude/cache -maxdepth 1 -type f -name 'vendor-glm-*' -print -quit | grep -q .
```

Expected: exit 0。

- [ ] **Step 4: 驗證輪詢不再重新產生快取**

Run:

```bash
sleep 70
! find ~/.claude/cache -maxdepth 1 -type f -name 'vendor-glm-*' -print -quit | grep -q .
```

Expected: 超過兩個 30 秒 alarm 週期後仍為 exit 0。

### Task 4: 最終範圍與行為驗證

**Files:**
- Verify: `scripts/wrapper.sh`
- Verify: `~/.claude/scripts/cc-statusline/wrapper.sh`
- Verify: 最新 widget-log JSONL

**Interfaces:**
- Consumes: Tasks 1–3 的完成狀態。
- Produces: GLM 活路徑已停止、基礎建設仍保留的驗證證據。

- [ ] **Step 1: 枚舉 source 與 runtime 的 GLM 引用**

Run:

```bash
grep -nEi 'glm|z\.ai' scripts/wrapper.sh
grep -nEi 'glm|z\.ai' ~/.claude/scripts/cc-statusline/wrapper.sh
```

Expected: 仍可看到 formatter、helper、變數與樣式；看不到 `fmt_glm_quota 2>/dev/null` 或 `--arg glm_*`。

- [ ] **Step 2: 強制產生一筆新的 widget-log**

Run:

```bash
printf '0' > /tmp/cc-widget-cache/.widget-log-last-ts
printf '%s' '{"workspace":{"current_dir":"/Users/linhancheng/Desktop/projects/cc-statusline-widgets"},"model":{"display_name":"Claude"},"session_id":"glm-retirement-log-check"}' | bash ~/.claude/scripts/cc-statusline/wrapper.sh >/tmp/cc-statusline-glm-retirement-log.out
```

Expected: wrapper exit 0，當月 widget-log 追加一筆記錄。

- [ ] **Step 3: 驗證最新記錄沒有 GLM schema**

Run:

```bash
LATEST_LOG="$HOME/.claude/projects/widget-log/$(date +%Y-%m).jsonl"
jq -se 'last | (has("glm_level") or has("glm_5h_pct") or has("glm_w_pct")) | not' "$LATEST_LOG"
```

Expected: jq 輸出 `true` 且 exit 0。

- [ ] **Step 4: 最終工作目錄與 commit 檢查**

Run:

```bash
git status --short
git log -3 --oneline
```

Expected: tracked 工作目錄乾淨；最近三筆 commit 依序包含驗證計畫修正、GLM 實作與設計規格。
