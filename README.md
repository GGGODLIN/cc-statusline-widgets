# cc-statusline-widgets

自製 Claude Code statusline — 砍 ccstatusline，wrapper + daemon hybrid 架構。動機是**擴展性**（未來想加 N 個 web API widget / OS metric / 自定 widget 不受第三方限制）。

## Status

2026-04-27 起步並 pivot 兩次（D-route → E-route）。**Phase 3 實作完成可驗收**。

## 安裝（cross-machine 通用）

```bash
git clone <repo> ~/Desktop/projects/cc-statusline-widgets
cd ~/Desktop/projects/cc-statusline-widgets
bash scripts/install.sh
```

### 依賴

- 內建：`bash`, `jq`, `awk`, `iostat`, `vm_stat`
- thermals widget（CPU/GPU 溫度 + 風扇 RPM，Apple Silicon only）：
  ```
  brew install macmon mactop
  ```
  沒裝會顯示 `🌡️ ?`，其他 widget 不受影響。

`install.sh` 做：
1. 拷貝 wrapper / daemon / free-memory script 到 `~/.claude/scripts/cc-statusline/`
2. 拷貝 plist 到 `~/Library/LaunchAgents/`
3. `launchctl bootstrap` 啟動 daemon（idempotent — 重跑 OK）

接著手動把 `~/.claude/settings.json` 的 `statusLine.command` 改成：

```
/Users/<USERNAME>/.claude/scripts/cc-statusline/wrapper.sh
```

## 架構

```
[Wrapper — statusLine.command]                   [後台 daemon — launchd KeepAlive]
~/.claude/scripts/cc-statusline/wrapper.sh        ~/.claude/scripts/cc-statusline/daemon.sh
   │ CC 觸發 (event/refreshInterval)                  │ while true 自己 cycle
   ▼ ~130ms cold start                                ▼ per-widget cycle
   1. jq 解析 stdin                                ─ battery  (1s)  → cc-statusline-battery.sh
   2. 當場算（依賴 cc session）：                    ─ disk     (60s) → disk-usage.sh
      - model (stdin)                              ─ memory   (5s)  → free-memory.sh
      - session-cost (stdin cost.total_cost_usd)   ─ cpu      (5s)  → cpu-usage.sh
      - context-bar (stdin context_window)         ─ thermals (5s)  → thermals.sh (macmon)
      - git-branch / ahead-behind (cwd)            另外 fork 一個 30s 背景 loop 跑 mactop
      - cache / tok/s / TTFT (transcript)          寫 .mactop-fan.json，給 thermals 讀風扇

                                                   寫到 /tmp/cc-widget-cache/<name>.txt
                                                   (atomic write via tmp+mv)
   3. 跑 ~/.claude/scripts/usage-color.sh (Line 2 — optional external script)
   4. cat /tmp/cc-widget-cache/{battery,disk,memory}.txt
   5. 拼接 3 行 ANSI 輸出
```

## usage-color.sh 的新鮮度門檻

`scripts/usage-color.sh` 是 Line 2 的 quota pill renderer。它不部署到 `$DEST`，而是 `~/.claude/scripts/usage-color.sh`——`wrapper.sh` 從那裡讀。`install.sh` 已含這一步。

pill 上的 `[N old]` / `[⚠ N stale]` 是拿 cache 檔 mtime 算的，門檻兩個常數，可用同名環境變數覆寫：

| 常數 | 預設 | 意義 |
|---|---|---|
| `OLD_AFTER_SECONDS` | 400 | 黃字 `[N old]` |
| `STALE_AFTER_SECONDS` | 600 | 紅字 `[⚠ N stale]` |

門檻必須對齊**最慢的 writer**。目前兩個 writer 寫同一批 `quota-<email>.json`：Chrome 外掛 30 秒一輪，`cc-quota-fetcher` 的 `anthropic_quota_poller` 180 秒一輪。400 秒 = 慢的那個連續漏兩輪才提醒。

舊值是 90 秒，那是只有 30 秒外掛時定的。poller 改成 180 秒後，90 秒門檻會讓 pill 在每個輪詢週期有一半時間掛著 `[2m old]`，而那半段其實一切正常——警告失去資訊量。**動任一 poller 的輪詢間隔時，這兩個門檻要一起調。**

## Phase 3 實作驗收

| Widget | 來源 | 狀態 |
|---|---|---|
| Model | stdin `.model.display_name` | ✅ |
| Skill | `skill-hook.sh`（PreToolUse(Skill) + UserPromptSubmit hook）寫 per-session 檔 | ✅ |
| Git branch + ahead/behind | git command（cwd from stdin） | ✅ |
| Cost | stdin `.cost.total_cost_usd` | ✅ |
| Line 2 (optional external) | `~/.claude/scripts/usage-color.sh` if exists, else skipped | ✅ |
| Context bar | stdin `.context_window.used_percentage` + 進度條 | ✅ |
| Cache 命中率 / 閒置 | transcript 最後一輪 cache token | ✅ |
| tok/s + TTFT | transcript 時間戳與 thinkingDurationMs（見 widget-log 段） | ✅ |
| Free memory | daemon → vm_stat 算 active+wired（htop 式） | ✅ |
| Disk | daemon → `disk-usage.sh` (Container Free Space) | ✅ |
| Battery | daemon → `cc-statusline-battery.sh` | ✅ |
| Thermals (CPU/GPU 溫度 + 風扇 RPM) | daemon → `thermals.sh` (macmon + mactop cache) | ✅ |
| Subagent 面板 | `subagent-panel.sh`（`subagentStatusLine`，見 CLAUDE.md） | ✅ |

### Cold start benchmark

| | Cold start | 1Hz CPU 預估 |
|---|---|---|
| ccstatusline (替換前) | 430ms | 43% 一核 |
| **本 wrapper** | **~130ms (10 次取樣 0.10-0.18s)** | **~13% 一核** |

提速 ~3.3×。1Hz refreshInterval 變得可行（之前 ccstatusline 不行）。

## 卸載

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.user.cc-statusline-daemon.plist
rm ~/Library/LaunchAgents/com.user.cc-statusline-daemon.plist
rm -rf ~/.claude/scripts/cc-statusline
# 把 settings.json statusLine.command 改回 "ccstatusline"
```

## 已知限制

- **Hardcoded `/Users/linhancheng`** — daemon plist 跟 daemon.sh 寫死路徑。換機要重跑 install.sh，路徑不同會壞。

## Phase 進度

- [x] **Phase 1** Reverse-engineer ccstatusline → [docs/reverse-engineering.md](docs/reverse-engineering.md)
- [x] **Phase 2** bash decision → [docs/decisions.md](docs/decisions.md)
- [x] **Phase 3** 實作完成（commit pending）
  - [x] wrapper.sh
  - [x] daemon.sh + free-memory.sh
  - [x] launchd plist
  - [x] install.sh
  - [x] settings.json 切到 wrapper
  - [x] 驗證輸出對齊 + cold start 測試
  - [x] **觀察期通過 → ccstatusline 完全清乾淨 (2026-04-27)**
    - `npm uninstall -g ccstatusline`
    - settings.json 移除 PreToolUse(Skill) + UserPromptSubmit 兩個 `ccstatusline --hook` 引用
    - 移除 `~/.config/ccstatusline/` config dir
    - 移除 dev-only `compare.sh` + wrapper 內 stdin dump
    - 改 `refreshInterval=1` 配 1Hz 拔線秒看到

## ADR

詳見 [docs/decisions.md](docs/decisions.md)
- ADR-001 砍 ccstatusline
- ADR-002 bash + jq（不用 Go）
- ADR-003 統一 daemon（不走 per-widget plist）

## Cross-machine

需要 cross-machine task — launchd plist + script 路徑都 macOS-specific 且 hardcoded。

## History

```
c529414 docs: Phase 1 reverse-engineering + Phase 2 bash decision
68cbe8c chore: reset for E architecture rewrite
542e498 feat: cc-statusline-widgets M1 battery PoC (D-route, lessons learned)
```

## 故障排除

```bash
# Daemon 沒跑？
launchctl list | grep cc-statusline-daemon
ps aux | grep cc-statusline-widgets | grep -v grep
cat /tmp/cc-statusline-daemon.log

# 看 daemon 寫的 cache
ls -la /tmp/cc-widget-cache/
cat /tmp/cc-widget-cache/battery.txt

# 手動跑 wrapper 看輸出
echo '{"model":{"display_name":"Sonnet"}}' | ~/.claude/scripts/cc-statusline/wrapper.sh
```

## Widget snapshot log

Wrapper writes a 5-minute-throttled JSONL snapshot of all widget values to
`~/.claude/projects/widget-log/YYYY-MM.jsonl`. The directory lives inside the
`claude-session-backups` git repo, so the daily 02:00 launchd job backs it
up automatically (append-only policy applies).

**Methodology rule**: the statusline is the curation source of truth. When
adding, removing, or renaming widgets in `wrapper.sh`, update the
`widget-log` jq snapshot block in lockstep so the log always mirrors what's
on screen. The whole point is "future analysis of indicators I cared about
enough to display" — drift between screen and log destroys that signal.

Schema (per JSONL line):
`ts cwd session_id model effort cost codex_weekly_remaining_pct codex_weekly_used_pct codex_weekly_reset_at grok_weekly_used_pct grok_weekly_reset_at grok_bot_used_pct grok_bot_reset_at cache_hit cache_flushes cache_waste cache_idle cache_compactions tps tps_decode ttft ctx_pct ctx_tokens skill subagents git_branch git_ab runaway cpu thermals free_mem disk battery line1 line2 line3`

`tps` 是目前模型最近 5 個合格回應的整體輸出率中位數：輸出至少 200 token，
完整耗時大於 0.5 秒且不超過 900 秒。計算包含等待時間；widget-log 在少於
2 個合格回應時記 `--`，沒有 transcript 時留空。

模型名稱以 `gpt-` 開頭時，pill 固定顯示整體輸出率，不依 `thinkingDurationMs`
選擇算法。GPT 的思考區塊可能整包落筆，記錄到 2ms 以上也不能證明生成時間；
`tps_decode` 因此留空，`ttft` 估計從請求紀錄到第一個思考區塊落筆的等待時間。
這不是純吐字速度，也不是 relay 或畫面端的實測 TTFT。

其他模型維持原有判定：思考時長 ≥2ms 時，`tps_decode` 估計首 token 到最後
一個 token 的速度；較短時使用整體速度。pill 格式仍為 `⚡<速度> t/s ⏱ <等待>s`，
單筆合格回應也可顯示速度；沒有可用的思考時間標記時整格隱藏。

`line1/2/3` retain ANSI escapes for full statusline replay. All numeric
fields are stored as strings — convert with `jq tonumber` when querying.

Estimated growth: ~70 MB/year (96 samples/day × ~2 KB, assuming heavy CC
use). Throttle is global across sessions; if multiple CC sessions are
active simultaneously, only the first wrapper invocation per 5-min window
writes a sample.

Query example — daily cost trend:
```bash
jq -r '[.ts[:10], (.cost|tonumber)] | @tsv' \
  ~/.claude/projects/widget-log/2026-05.jsonl \
  | awk '{a[$1]+=$2} END {for(k in a) print k, a[k]}' | sort
```

## Web statusline bridge

For consumers that want to render the statusline outside the terminal (e.g., a sibling web-render project consuming these files via SSE):

- **`/tmp/cc-widget-cache/by-intl-uuid/<uuid>.json`** — `wrapper.sh` writes the full CC stdin payload here every cc-statusline refresh, keyed by the intl uuid resolved via `~/.cc-i18n-proxy/intl-uuid-by-key/<KEY>.uuid` (KEY = `CMUX_SURFACE_ID || cc_session_id || sha256(cwd)[:12]`).
- **`/tmp/cc-widget-cache/<metric>.json`** — `daemon.sh` writes `{display, ts}` JSON companions for `cpu / memory / thermals / disk / battery` alongside the existing ANSI `.txt` files.

Consumers should read these files directly; mtime > 30s for the per-uuid file or mtime > 60s for host metrics indicates the source is stale.
