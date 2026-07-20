# GLM 數據休眠設計

**日期：** 2026-07-20

## 背景

GLM Coding Plan 已退訂，但目前仍有兩條活路徑：

1. `cc-statusline-widgets` 每次執行 wrapper 時讀取 GLM 快取，並把 GLM pill 加到 statusline 第 2 行。
2. `cc-quota-fetcher` 每 30 秒輪詢一次 GLM quota；退訂後持續寫入「目前使用者不存在 coding plan」的狀態快取。

目標是停止 GLM 數據的顯示、記錄與背景抓取，同時保留未來重新訂閱後可復用的完整基礎建設。

## 決策

採用「完整休眠、保留基礎建設」方案。

這次只解除 GLM 的活接線，不刪除 formatter、抓取程式、Chrome extension 設定介面、native receiver 支援、樣式變數或歷史資料。

## 變更範圍

### Statusline 顯示

從 `scripts/wrapper.sh` 移除：

- `GLM_PILL_OUT` 與 `GLM_PILL_BG` 的顯示前初始化。
- `fmt_glm_quota` 的執行接線。
- 將 `GLM_PILL_OUT` 加入 statusline 第 2 行的 `push_seg` 接線。

`fmt_glm_quota()`、`fmt_glm_countdown()`、`quota_pct_color()`、GLM 暫存變數及 GLM 色彩設定全部保留。

### Widget log

從 wrapper 末尾的 `$ARGS.named` 輸入移除：

- `glm_level`
- `glm_5h_pct`
- `glm_w_pct`

既有月份 JSONL 中的歷史 GLM 欄位不回寫、不清除。變更後只影響新追加的記錄。

### 背景輪詢與快取

使用 `cc-quota-fetcher` 已有的 vendor 開關停用 GLM：

1. 將 Chrome extension 儲存的 `vendor_enabled.glm` 設為 `false`。
2. 觸發既有的 `vendor-disable` 訊息。
3. background script 發送 `vendor-clear` 給 native receiver。
4. receiver 清除目前 profile 對應的 `vendor-glm-*.json`、`vendor-glm-*.status` 與相容的 plan 快取。
5. 後續 alarm tick 因 `cfg.glm` 為 false，不再呼叫 `fetchGlmQuota()`。

不修改 `cc-quota-fetcher` source；未來重新勾選 GLM 即可恢復抓取。

## 保留的基礎建設

- GLM cache formatter 與 quota schema 解析。
- GLM 倒數、百分比色階與尖峰時段樣式。
- Chrome extension 的 GLM 開關、API key 欄位與 API 抓取函式。
- `https://api.z.ai/*` host permission。
- native receiver 的 GLM vendor 白名單、寫入與清理能力。
- GLM 設計文件、實作計畫與歷史 SDD 產物。
- 既有 widget-log 歷史資料。

## 部署策略

repo source 是 `scripts/wrapper.sh`，Claude Code 實際執行的是 `~/.claude/scripts/cc-statusline/wrapper.sh`。

目前 runtime 副本另有兩行與 GLM 無關的 model cache 寫入，直接複製 repo source 會覆蓋這項未納入本次範圍的差異。因此部署採精確同步：

- 在 repo source 移除 GLM 活接線。
- 在 runtime 副本移除相同的 GLM 活接線。
- 保留 runtime 既有的非 GLM 差異。

這仍會讓本次 GLM 變更立即作用於真正執行的 runtime，同時避免修改無關行為。

## 資料流

變更前：

`Chrome alarm → GLM API → native receiver → GLM cache → wrapper formatter → statusline + widget-log`

變更後：

`Chrome alarm → vendor_enabled.glm=false → 跳過 GLM API`

wrapper 不再呼叫 GLM formatter，因此不讀 GLM cache、不產生 GLM pill，也不建立新的 GLM widget-log 欄位。保留的 formatter 與抓取元件沒有活接線，但可在未來重新接回。

## 錯誤處理

- 若 Chrome extension 無法直接由自動化工具操作，改由使用者在 popup 取消勾選 GLM；不以修改 source 預設值代替，因既有 Chrome storage 會覆蓋預設值。
- 若 `vendor-clear` 未清除快取，先檢查 native receiver 是否收到訊息，再使用既有清理路徑處理；不刪除其他 vendor 快取。
- 若 runtime 輸出仍有 GLM，優先確認實際執行檔是 runtime 副本，而不是只驗證 repo source。

## 驗證

1. 對 repo source 與 runtime 副本執行 `bash -n`，確認 shell 語法有效。
2. 使用實際 statusline stdin 執行 runtime wrapper，確認輸出不包含 `GLM`。
3. 確認同一份輸出中原有的 DS 等非 GLM pill 未受影響。
4. 讓 widget-log 節流條件可產生一筆新記錄，確認新記錄不包含 `glm_level`、`glm_5h_pct`、`glm_w_pct`。
5. 停用 GLM 後確認現有 `vendor-glm-*` 快取已清除。
6. 等待超過兩個 30 秒 alarm 週期後再次確認 GLM 快取沒有重新產生。
7. 枚舉 repo source 與 runtime 的 GLM 引用，確認只移除顯示與記錄接線，formatter、樣式與其他基礎建設仍存在。

## 不在本次範圍

- 不刪除 GLM formatter 或 helper。
- 不刪除 `cc-quota-fetcher` 的 GLM 程式。
- 不修改新安裝時的 GLM 預設開關。
- 不刪除 API key、host permission 或 receiver vendor 支援。
- 不清理既有 widget-log 歷史。
- 不修改其他 vendor 的顯示、抓取或快取。
- 不處理 runtime 副本中與 GLM 無關的兩行差異。
