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

## Subagent pill（🤖 N）只數總量，不數活躍

`subagent-count.sh` 數 `<transcript_path 去掉 .jsonl>/subagents/*.meta.json`，只算 `spawnDepth == 1`
（main session 自己派的；agent 再派的那層不重複計）。CC 在派工當下就寫 meta，不是結束才寫。

**刻意不顯示活躍數**：CC 原生 agent panel（prompt 下方）本來就即時列出正在跑的 subagent，
statusline 再報一次是重複。panel 在跑完後會消失，累計總量才是別處留不住的東西。

2026-09-14 曾接過一版活躍數（`subagentStatusLine` 採集器 + `toolUseId` 對帳），實測準確
（agent 起跑 2 秒內亮、結束 2 秒內滅），因重複而移除，見 `git log` f1ac30c。要復原去翻那個 commit。

## 改 daemon-side script 要 restart daemon

daemon 5s cycle 才 reload，改 `daemon.sh` 的 `WIDGETS` array 後 `install.sh` 會 bootout/bootstrap。
立即 refresh 單一 widget cache：`rm /tmp/cc-widget-cache/.last-<name> && sleep <cycle+1>`
