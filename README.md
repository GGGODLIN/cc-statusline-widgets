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
      - tokens-total (stdin current_usage 加總)
      - git-branch / ahead-behind (cwd)            另外 fork 一個 30s 背景 loop 跑 mactop
      - session-clock (transcript first ts)        寫 .mactop-fan.json，給 thermals 讀風扇

                                                   寫到 /tmp/cc-widget-cache/<name>.txt
                                                   (atomic write via tmp+mv)
   3. 跑 ~/.claude/scripts/usage-color.sh (Line 2 — optional external script)
   4. cat /tmp/cc-widget-cache/{battery,disk,memory}.txt
   5. 拼接 3 行 ANSI 輸出
```

## Phase 3 實作驗收

| Widget | 來源 | 狀態 |
|---|---|---|
| Model | stdin `.model.display_name` | ✅ |
| Skill | (stub `Skill: -`) | ⚠️ known limitation — 第一版未做 |
| Git branch + ahead/behind | git command（cwd from stdin） | ✅ |
| Cost | stdin `.cost.total_cost_usd` | ✅ |
| Session clock | transcript first timestamp | ✅（無 transcript 時 fallback `-`） |
| Line 2 (optional external) | `~/.claude/scripts/usage-color.sh` if exists, else skipped | ✅ |
| Context bar | stdin `.context_window.used_percentage` + 進度條 | ✅ |
| Tokens total | stdin `.context_window.current_usage` 4 欄加總 | ✅ |
| Free memory | daemon → vm_stat 算 free+inactive+spec | ✅ |
| Disk | daemon → `disk-usage.sh` (Container Free Space) | ✅ |
| Battery | daemon → `cc-statusline-battery.sh` | ✅ |
| Thermals (CPU/GPU 溫度 + 風扇 RPM) | daemon → `thermals.sh` (macmon + mactop cache) | ✅ |

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

- **Skills widget** — stub `-`。要 reverse engineer ccstatusline `--hook` 機制（PreToolUse(Skill) + UserPromptSubmit 寫的 state file 在哪），第二版補。
- **Session clock** — 從 transcript 第一行 timestamp 算，無 transcript 時 fallback `-`。CC 有時候 stdin 沒給 transcript_path（preview 模式）會看到。
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

## Web statusline bridge

For consumers that want to render the statusline outside the terminal (e.g., a sibling web-render project consuming these files via SSE):

- **`/tmp/cc-widget-cache/by-intl-uuid/<uuid>.json`** — `wrapper.sh` writes the full CC stdin payload here every cc-statusline refresh, keyed by the intl uuid resolved via `~/.cc-i18n-proxy/intl-uuid-by-key/<KEY>.uuid` (KEY = `CMUX_SURFACE_ID || cc_session_id || sha256(cwd)[:12]`).
- **`/tmp/cc-widget-cache/<metric>.json`** — `daemon.sh` writes `{display, ts}` JSON companions for `cpu / memory / thermals / disk / battery` alongside the existing ANSI `.txt` files.

Consumers should read these files directly; mtime > 30s for the per-uuid file or mtime > 60s for host metrics indicates the source is stale.
