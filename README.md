# cc-statusline-widgets

把 ccstatusline 的 custom-command widget 從「**每次 trigger 都跑 script**」解耦成「**daemon 各自 cycle 寫檔，render 時只 cat**」。

## 動機

ccstatusline 是純 render 工具，不是 daemon — 每次 CC 觸發 statusLine.command 就把 12 個 widget 全部重 render 一次。對「跑 script 拿外部資料」的 custom-command widget（battery / disk / quota）有兩個痛點：

1. **每次 render 都跑 script** — 連 5s 沒變的東西也要重算
2. **所有 widget 綁同一個 trigger** — battery 充電拔插想立刻看到，但 disk 60s 變化慢，trigger 卻是同一個

解決：每個 widget 一個 background daemon 自己 cycle 寫檔，ccstatusline 的 custom-command 改成 `cat` shim — render 時 1ms 級。

## 架構

```
[Daemon 層 — 各自 cycle 寫檔]
launchd LaunchAgent  →  widgets/battery-daemon.sh  →  /tmp/cc-widget-battery.txt   (5s)
                        widgets/disk-daemon.sh     →  /tmp/cc-widget-disk.txt      (60s, 未做)
chrome alarm         →  cc-quota-fetcher           →  ~/.claude/cache/quota-*.json (30s, 已實作)
                        widgets/quota-daemon.sh    →  /tmp/cc-widget-quota.txt     (30s, 未做)

[Render 層 — 純 cat，1ms/widget]
ccstatusline custom-command  →  widgets/cat-battery.sh  →  cat /tmp/cc-widget-battery.txt
                                widgets/cat-disk.sh
                                widgets/cat-quota.sh
```

CC 觸發 statusline 的時機（不變）：
- 時間驅動：`refreshInterval`（目前 30s）保底
- 事件驅動：prompt submit / AI 完成 / mode toggle

User 看到的 latency = max(daemon cycle, CC trigger 間隔)。Battery 拔線後通常 < 30s 就會跟 cc 互動一次，那一刻 file 已是最新。

## 命名約定

| 類型 | Path pattern |
|---|---|
| Daemon script | `widgets/<name>-daemon.sh` |
| Cat shim | `widgets/cat-<name>.sh` |
| 寫檔位置 | `/tmp/cc-widget-<name>.txt` |
| Atomic 暫存 | `/tmp/cc-widget-<name>.txt.tmp` → `mv` |
| launchd Label | `com.user.cc-widget-<name>` |
| Plist file | `launchd/com.user.cc-widget-<name>.plist` |

## 為什麼用 KeepAlive 而不是 StartInterval

macOS launchd 對 `StartInterval < 60s` 不穩 — 會被 coalesce 到 60s。要 5s cycle 必須用常駐 daemon（while-loop sleep 5），加 `KeepAlive=true` + `RunAtLoad=true` 讓 launchd 保證一直跑、crash 自動拉起。

## Atomic write

```bash
printf '%s' "$out" > /tmp/cc-widget-X.txt.tmp && mv /tmp/cc-widget-X.txt.tmp /tmp/cc-widget-X.txt
```

`mv` 在同一 filesystem 是 atomic — 避免 cat shim 讀到半寫的檔。

## Failure mode

Daemon 沒跑 / 寫檔失敗 → cat shim 看到 file 不存在或空 → fallback 預設字串（`🔋?` 等）→ statusline 不會空白。

## Milestones

- [x] **M0** Skeleton + README
- [x] **M1 battery PoC** (2026-04-27) — 跑通整個 daemon → file → cat → statusline pipeline
- [ ] **M2 disk** — 同模式（ROI 較低，看 M1 結果決定要不要做）
- [ ] **M3 quota** — usage-color.sh render 邏輯抽進 quota-daemon.sh

## M1 實作紀錄 (2026-04-27)

### 安裝步驟

```bash
cp launchd/com.user.cc-widget-battery.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.cc-widget-battery.plist
```

ccstatusline `~/.config/ccstatusline/settings.json` 把 battery widget 的 `commandPath` 從 `~/.claude/scripts/cc-statusline-battery.sh` 換成 `widgets/cat-battery.sh`。

### 驗證結果

| # | Check | 結果 |
|---|---|---|
| 1 | Daemon process 在 | ✅ PID 跑著 |
| 2 | `/tmp/cc-widget-battery.txt` mtime 在 5s cycle 內 fresh | ✅ |
| 3 | cat shim 輸出 `🔌94W ⚡+13.9W` 綠色 ANSI | ✅ |
| 4 | ccstatusline 第 3 行末尾跟 cat 內容一致 | ✅ |
| 5 | 拔充電器 5s 後 file 內容變 `🔌` → `🔋` | 待 user 實測 |

### 卸載

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.cc-widget-battery.plist
rm ~/Library/LaunchAgents/com.user.cc-widget-battery.plist
```

回滾 ccstatusline 的 `commandPath` 即可恢復舊行為。

## 觀察期

跑一陣子看：
- daemon 是否穩定（log: `/tmp/cc-widget-battery.daemon.log`）
- launchd 對 KeepAlive bash while-loop 的 CPU 影響
- 拔線→看到變化的實際 user-perceived latency

## Cross-machine

launchd plist 是 macOS-specific — sync 到別台機器需要：
1. Plist file 拷到 `~/Library/LaunchAgents/`
2. `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<plist>`
3. 確認 daemon script paths 對齊（如果 home dir 名字不同會壞）

## 相關 memory

- [reference_ccstatusline_account_quota_widgets.md](file:///Users/linhancheng/.claude/projects/-Users-linhancheng-Desktop-projects/memory/reference_ccstatusline_account_quota_widgets.md) — ccstatusline 環境完整紀錄
- [reference_claude_code_statusline_refresh_triggers.md](file:///Users/linhancheng/.claude/projects/-Users-linhancheng-Desktop-projects/memory/reference_claude_code_statusline_refresh_triggers.md) — CC statusline trigger 機制
