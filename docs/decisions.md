# Architecture Decisions

## ADR-001: 砍 ccstatusline 改自製 (E architecture)

**Date**: 2026-04-27
**Status**: Accepted

### Context

cc-statusline-widgets 一開始走 D-route（留 ccstatusline + custom-command 改 cat shim）。M1 battery PoC 跑通但對 user 真痛點「拔線立刻看到」沒實質幫助 — UI render 時機由 CC `statusLine.command` trigger 控制，背後 daemon cycle 多快都被 CC 30s/event-driven 卡住。

User 動機從「battery 立刻看到」轉成「**未來擴展性 + 自製基底**」（加各種 web API widget / OS metric / 自定 widget 不用受 ccstatusline 限制）。

### Decision

砍 ccstatusline，走 E-route：
- 自製 wrapper bash script 當 statusLine.command（B 部分：依賴 stdin 的當場算）
- 後台 daemon 算 stdin 沒有 / 不依賴 cc session 的（C 部分）
- CC trigger 時 wrapper jq stdin + cat daemon files + 拼接

### Trade-offs

✅ **拿到的**：
- 完全控制 widget 集合 / layout
- 加 widget 一個 if 分支，不受 ccstatusline 限制
- Cold start 30-80ms（vs ccstatusline 430ms）→ 1Hz 可行
- 各 widget 獨立 cycle（daemon 部分）

❌ **付的代價**：
- ccstatusline 11 個內建 widget 邏輯要自寫
- 跟 ccstatusline upstream 改動脫鉤（自己維護）
- 部分 widget（skills）邏輯複雜度待評估

### Alternatives considered

- **A 留現狀** — 對擴展性沒幫助
- **D Hybrid 解耦**（M1 已試）— 對 user 真痛點 cosmetic 改善
- **C 純 daemon** — daemon 拿不到 stdin，transcript path race
- **B 純 wrapper bash 1Hz** — 失去後台 daemon 各自 cycle 的價值

---

## ADR-002: Wrapper 用 bash 不用 Go

**Date**: 2026-04-27
**Status**: Accepted（基於 Phase 1 逆向結果）

### Context

Phase 1 逆向 ccstatusline 發現：CC stdin 已給 `cost.total_cost_usd` / `context_window.used_percentage` / `rate_limits` 等算好的數值。**transcript parse 是 fallback 不是必要**，pricing tier 計算 **完全不需要**（CC 自己算）。

工程量從之前估「200-300 行 + transcript parser + pricing tier」**降到 130-170 行 jq + bash**。

### Decision

**bash + jq**。

### Reasoning

| | bash | Go binary |
|---|---|---|
| Cold start | 30-80ms | <30ms |
| 1Hz CPU | 3-8% 一核 | <3% |
| 工程量 | **130-170 行** | 500-800 行 + build pipeline |
| Iteration 速度 | 改檔即生效 | 改 → build → 測 |
| 跨平台（之後 Linux？） | bash 通用 | 要 cross-compile |

bash 的 cold start 30-80ms 跟 1Hz CPU 3-8% 完全可接受。Go 的速度優勢（再快 50ms）對 user 體感無差別。**bash 工程量小 ~5x 是更大的 win**。

### When to revisit

如果發現某個 widget 在 bash 寫得特別痛苦（例如 transcript parser fallback 太複雜），可以**單獨**那塊用 Go / Rust binary，wrapper bash 呼叫該 binary。混用比全 Go 重寫便宜。

---

## ADR-003: M1 battery daemon 模式保留作為 daemon 基底

**Date**: 2026-04-27
**Status**: Accepted

### Context

M1 已實作的 daemon pattern（launchd KeepAlive + while-loop sleep + atomic write + cat shim）對 D-route 沒有解到 use case，但**架構本身對 E-route 的 daemon 部分是直接基底**。

### Decision

git history 留著 commit `542e498`（M1 PoC），**新檔結構不再延續 M1 那種「per-widget 獨立 daemon」的設計**，改成「**一支 daemon 統一管所有 daemon-side widget**」（cycle interval 在 daemon 內 per-widget 控制）— 比較好管 launchd plist 數量。

### Reasoning

per-widget daemon → N 個 plist（N=widget 數）：
- 每加一個 widget 要新建 plist + launchctl bootstrap
- 跨機 sync 要拷 N 個 plist + N 次 bootstrap
- 管理開銷 O(N)

統一 daemon → 1 個 plist：
- 所有 daemon-side widget 邏輯集中
- daemon 內部用 sleep timer + 不同 cycle 控制 per-widget 何時 update
- 跨機 sync 一個 plist 就夠

但保留 M1 atomic-write + /tmp/cc-cache/<name>.txt 的命名 pattern。
