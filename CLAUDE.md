# cc-statusline-widgets — 開發須知

## ⚠️ 改完一定要部署（最容易踩的坑）

CC 的 statusline 實際跑的是 install.sh 部署出的副本，**不是這個 repo 的 source**：

- runtime（CC 真正執行）→ `~/.claude/scripts/cc-statusline/wrapper.sh`
- repo source（你在改的）→ `scripts/wrapper.sh`

**改任何 script（含只改既有 widget 邏輯、不只是加新 widget）後必須重新部署**，否則畫面完全不變：

- 全量：`bash scripts/install.sh`（cp 所有 script + plist + bootstrap daemon）
- 單檔最小侵入：`cp scripts/wrapper.sh ~/.claude/scripts/cc-statusline/wrapper.sh`（不碰 daemon/launchd）

**verify 要對 runtime 副本，不是 repo 檔**：

```bash
bash ~/.claude/scripts/cc-statusline/wrapper.sh < stdin.json
```

對 repo 檔跑「驗證通過」但 user 看不到 = verify 對錯了檔。

## 改 widget 要同步 widget-log schema

`wrapper.sh` 末尾 `widget-log` 段（`$ARGS.named` 那個 jq）是指標歷史的 source of truth。
新增 / 移除 / 改名 widget 時，同步加減對應的 `--arg`，否則歷史指標漂移、無法回溯分析。

## 帳號 pill 靠 OTel，不是靠 .claude.json

`usage-color.sh` 排第一的帳號來自 `/tmp/cc-widget-cache/session-account.json`（`session_id → email`），
由 `session-account-receiver.py` 收 CC 送出的 OTel metric 寫成。斷了任何一環，pill 會退回
`$HOME/.claude.json` 並在帳號名後加 `?`（多 session 下那個值不可信——CC 憑證是 per-process 的，
一個 session 跑 `/login` 不會換掉其他正在跑的 session）。

三環都要在：

1. `~/.claude/settings.json` 的 `env` 有 `CLAUDE_CODE_ENABLE_TELEMETRY` 等 5 個 OTEL 變數（**這在 repo 外**，重裝機器要另外補）
2. daemon 有起 receiver 子行程（`lsof -nP -iTCP:4318 -sTCP:LISTEN` 看得到 Python）
3. `wrapper.sh` 呼叫 `usage-color.sh` 時帶 `CC_SESSION_ID`

map 只在 session 啟動後約 10 秒（metric export interval）才出現，且**既有 session 沒帶 env 就永遠不會進 map**。

## Subagent pill（🤖 活躍/累計）踩在兩個來源上

`subagent-count.sh` 出的 `🤖 2/8`，兩個數字來源不同：

- **累計（8）**：數 `<transcript_path 去掉 .jsonl>/subagents/*.meta.json`，只算 `spawnDepth == 1`
  （main session 自己派的）。CC 在派工當下就寫 meta，不是結束才寫。
- **活躍（2）**：優先讀 `subagent-statusline.sh` 寫的 `/tmp/cc-widget-cache/subagents-<session_id>.json`，
  `ts` 在 15 秒內才採用；過期或沒有就回退 A 路線——meta 的 `toolUseId` 在主 transcript
  還沒出現對應 `tool_result` 就算活躍。

兩個 repo 外的前提，重裝機器要另外補：

1. `~/.claude/settings.json` 的 `subagentStatusLine` 指向 `~/.claude/scripts/cc-statusline/subagent-statusline.sh`
   （**在 repo 外**）。沒有它只剩 A 路線，活躍數會慢一拍。
2. `statusLine.refreshInterval`（目前 1 秒）。沒設的話主 session 閒等 subagent 時 statusline 不重跑，
   活躍數會卡住不動——官方文件把這個設定明確標為此場景用。

A 路線擋不住 agent 被中止或 CC 當掉（`tool_result` 永遠不會來），所以有 stale 保護：
agent 自己的 jsonl 超過 `SUBAGENT_STALE_SEC`（預設 600 秒）沒寫入就不算活躍。

## 改 daemon-side script 要 restart daemon

daemon 5s cycle 才 reload，改 `daemon.sh` 的 `WIDGETS` array 後 `install.sh` 會 bootout/bootstrap。
立即 refresh 單一 widget cache：`rm /tmp/cc-widget-cache/.last-<name> && sleep <cycle+1>`
