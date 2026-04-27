# cc-statusline-widgets

自製 Claude Code statusline — 砍 ccstatusline，wrapper + daemon hybrid 架構，主動機是**擴展性**（未來想加 N 個 web API widget / OS metric / 自定 widget 不受第三方限制）。

## Status

2026-04-27 reset for E architecture rewrite。Phase 1 逆向完成，Phase 2 結論 = bash。Phase 3 實作中。

## 架構（E hybrid）

```
[Wrapper — statusLine.command]                  [後台 daemon — launchd]
~/.claude/scripts/cc-statusline.sh              一支統一 daemon
   │                                              │
   │  CC 觸發時跑（每秒/event）                       │  自己 cycle，per-widget interval
   ▼                                              ▼
   1. jq 解析 stdin                              ─ battery widget   (cycle 1s)
   2. 當場算依賴 cc session 的：                  ─ disk widget      (cycle 60s)
      - model（從 stdin）                        ─ free-memory      (cycle 5s)
      - session-cost（stdin cost.total_cost_usd） ─ subscription    (cycle 5min, claude.ai api)
      - context-bar（stdin context_window）       ─ ... 未來新 widget
      - tokens-total（stdin context_window）      │
      - quota 5h/7d（stdin rate_limits）         寫到：
      - git-branch / ahead-behind（cwd）         /tmp/cc-widget-cache/<name>.txt
   3. cat daemon files
   4. 拼接 3 行 ANSI 字串輸出
```

CC 觸發時 wrapper 跑：
- bash startup ~5ms
- jq stdin parse ~5ms
- widget render（含 git）~30-50ms
- cat daemon files ~1ms
- **Cold start 估 40-80ms**（vs ccstatusline 430ms）

## 動機

- 不為 battery「立刻看到」（那要走 osascript notification 不靠 statusline）
- 為**擴展性** — 加 widget 一個 if 分支
- 為**自由 cycle** — daemon-side 每個 widget 自己 interval
- 為**1Hz 可行** — wrapper cold start 40-80ms 配 1Hz refreshInterval CPU < 5% 一核

## 關鍵發現（Phase 1 逆向 ccstatusline）

CC stdin JSON **已給算好的**：cost / context_window / rate_limits / token usage。**transcript parse 是 fallback 不是必要**。詳見 [docs/reverse-engineering.md](docs/reverse-engineering.md)。

## Decisions

詳見 [docs/decisions.md](docs/decisions.md)

- ADR-001: 砍 ccstatusline 改自製
- ADR-002: bash + jq（不用 Go）
- ADR-003: 統一 daemon 不走 per-widget plist

## Phases

- [x] **Phase 1** Reverse-engineer ccstatusline transcript widgets（[docs/reverse-engineering.md](docs/reverse-engineering.md)）
- [x] **Phase 2** Decision: bash vs Go → **bash**（[docs/decisions.md](docs/decisions.md)）
- [ ] **Phase 3** 實作
  - [ ] wrapper script（bash + jq）
  - [ ] 統一 daemon（launchd）
  - [ ] settings.json statusLine.command 切到 wrapper
  - [ ] 平行運作觀察期 1-2 週
  - [ ] ccstatusline 移除（npm uninstall + hook config 清理）

## 跨機 sync

- wrapper script + daemon script 在 `~/.claude/scripts/`（git sync OK）
- launchd plist macOS-specific → 寫 cross-machine task

## 不做

- Skills widget（待評估，第一版可不做）
- 走 Go binary（ADR-002）
- 留 ccstatusline 並行（ADR-001）

## History

- `542e498` M1 D-route battery PoC（M1 lessons → ADR-001）
- `68cbe8c` Reset for E architecture rewrite
- (current) Phase 1 reverse-engineering + Phase 2 bash decision
