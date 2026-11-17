import { test } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { collectCodexPool, shortLabel, summarizeCodexPool } from "../scripts/codex-pool-usage.mjs";

const NOW_MS = Date.parse("2026-11-17T10:00:00Z");
const NOW_SEC = Math.floor(NOW_MS / 1000);
const FUT_5H = "2026-11-17T12:30:00Z";
const FUT_7D = "2026-11-20T10:00:00Z";
const PAST = "2026-11-17T09:00:00Z";

test("shortLabel formats aliases and fallback emails within 14 chars without control delimiters", () => {
  assert.equal(shortLabel("alpha@example.com", "Acme Business 工作區"), "Acme Biz");
  assert.equal(shortLabel("alpha@example.com", "VeryLongBusinessWorkspace工作區"), "VeryLongBizWor");
  assert.equal(shortLabel("alpha@example.com", "a:b|c\nd"), "abcd");
  assert.equal(shortLabel("alpha@example.com", ""), "alpha");
  assert.equal(shortLabel("alpha@example.com · Workspace123", null), "alpha·Work");
  assert.equal(shortLabel("verylongusername@example.com · ORG1", null), "verylonguserna");
  assert.equal(shortLabel("a:b|c@example.com · X:Y|Z", null), "abc·XYZ");
  assert.equal(shortLabel("", ""), "codex");
  assert.equal(shortLabel(":|:", ":|:"), "codex");
});

test("single-window promax, dual-window plus, image lane ignored, and expired reset resets used to 0", () => {
  const out = summarizeCodexPool(
    [
      {
        provider: "codex",
        user: "alpha@example.com",
        plan: "promax",
        lastServedAt: "2026-11-17T09:50:00Z",
        windows: [
          { name: "7 days", used: 42.4, resetsAt: "0001-01-01T00:00:00Z" },
          { name: "Image generation", lane: "images", used: 99 },
        ],
      },
      {
        provider: "codex",
        user: "beta@example.com",
        plan: "plus",
        lastServedAt: "2026-11-17T09:55:00Z",
        windows: [
          { name: "5 hours", used: 100, resetsAt: PAST },
          { name: "7 days", used: 20, resetsAt: FUT_7D },
          { name: "Image generation", lane: "images", used: 100 },
        ],
      },
    ],
    { nowMs: NOW_MS }
  );

  assert.equal(out.active.user, "beta@example.com");
  assert.equal(out.active.plan, "plus");
  assert.equal(out.active.used_5h_pct, 0);
  assert.equal(out.active.reset_5h_at, null);
  assert.equal(out.active.used_7d_pct, 20);
  assert.equal(out.avail_seats, 2);
  assert.equal(out.window_avail_seats, 2);
  assert.equal(out.total_seats, 2);
  assert.equal(out.accounts[0].order, 1);
  assert.equal(out.accounts[0].used_5h_pct, null);
  assert.equal(out.accounts[0].used_7d_pct, 42);
  assert.equal(out.accounts[0].reset_7d_at, null);
  assert.equal(out.accounts[0].is_active, false);
  assert.equal(out.accounts[1].order, 2);
  assert.equal(out.accounts[1].is_active, true);
});

test("lastServedAt exhausted switches active to first usable account; all full keeps latestServed", () => {
  const switched = summarizeCodexPool(
    [
      {
        provider: "codex",
        user: "alpha@example.com",
        plan: "promax",
        lastServedAt: "2026-11-17T09:30:00Z",
        windows: [{ name: "7 days", used: 100, resetsAt: FUT_7D }],
      },
      {
        provider: "codex",
        user: "beta@example.com",
        plan: "plus",
        lastServedAt: "2026-11-17T09:59:00Z",
        windows: [
          { name: "5 hours", used: 100, resetsAt: FUT_5H },
          { name: "7 days", used: 35, resetsAt: FUT_7D },
        ],
      },
      {
        provider: "codex",
        user: "gamma@example.com",
        plan: "team",
        lastServedAt: "2026-11-17T09:00:00Z",
        windows: [{ name: "7 days", used: 15, resetsAt: FUT_7D }],
      },
    ],
    { nowMs: NOW_MS }
  );
  assert.equal(switched.active.user, "gamma@example.com");
  assert.equal(switched.avail_seats, 1);

  const allFull = summarizeCodexPool(
    [
      {
        provider: "codex",
        user: "alpha@example.com",
        plan: "promax",
        windows: [{ name: "7 days", used: 100, resetsAt: FUT_7D }],
      },
      {
        provider: "codex",
        user: "beta@example.com",
        plan: "plus",
        lastServedAt: "2026-11-17T09:59:00Z",
        windows: [
          { name: "5 hours", used: 100, resetsAt: FUT_5H },
          { name: "7 days", used: 100, resetsAt: FUT_7D },
        ],
      },
    ],
    { nowMs: NOW_MS }
  );
  assert.equal(allFull.avail_seats, 0);
  assert.equal(allFull.active.user, "beta@example.com");
});

test("credits backup seat counts when window exhausted, cap >= 100, balance > 0, and not in codexNoCredits", () => {
  const out = summarizeCodexPool(
    [
      {
        provider: "codex",
        user: "alpha@example.com",
        plan: "plus",
        balance: "250.5 credits",
        windows: [
          { name: "5 hours", used: 100, resetsAt: FUT_5H },
          { name: "7 days", used: 100, resetsAt: FUT_7D },
        ],
      },
      {
        provider: "codex",
        user: "beta@example.com",
        plan: "plus",
        balance: "999.0 credits",
        windows: [
          { name: "5 hours", used: 100, resetsAt: FUT_5H },
          { name: "7 days", used: 100, resetsAt: FUT_7D },
        ],
      },
      {
        provider: "codex",
        user: "gamma@example.com",
        plan: "plus",
        balance: "50.0 credits",
        windows: [{ name: "7 days", used: 95, resetsAt: FUT_7D }],
      },
      {
        provider: "codex",
        user: "delta@example.com",
        plan: "plus",
        balance: "0.0 credits",
        windows: [{ name: "7 days", used: 100, resetsAt: FUT_7D }],
      },
    ],
    {
      nowMs: NOW_MS,
      codexNoCredits: ["BETA@EXAMPLE.COM"],
      accountCaps: { "gamma@example.com": 95 },
    }
  );

  assert.equal(out.avail_seats, 1);
  assert.equal(out.window_avail_seats, 0);
  assert.equal(out.active.user, "alpha@example.com");
  assert.equal(out.active.using_credits, true);
  assert.equal(out.accounts[1].usable, false);
  assert.equal(out.accounts[2].usable, false);
  assert.equal(out.accounts[3].usable, false);
});

test("free_pool aggregates codex-free and plugin:codex-free seats", () => {
  const r1 = "2026-11-25T10:00:00Z";
  const r2 = "2026-11-22T10:00:00Z";
  const out = summarizeCodexPool(
    [
      {
        provider: "codex",
        user: "alpha@example.com",
        plan: "promax",
        windows: [{ name: "7 days", used: 10, resetsAt: FUT_7D }],
      },
      {
        provider: "codex-free",
        user: "free1@example.com",
        windows: [{ name: "30 days", used: 20, resetsAt: r1 }],
      },
      {
        provider: "plugin:codex-free",
        user: "free2@example.com",
        windows: [{ name: "30 days", used: 100, resetsAt: r2 }],
      },
      {
        provider: "codex-free",
        user: "free3@example.com",
        error: "http-429",
        windows: [],
      },
    ],
    { nowMs: NOW_MS }
  );

  assert.deepEqual(out.free_pool, {
    avail_seats: 1,
    total_seats: 3,
    error_seats: 1,
    used_30d_pct: 60,
    next_reset_at: Math.floor(Date.parse(r2) / 1000),
  });
});

test("throws no-seats when zero codex rows exist", () => {
  assert.throws(
    () =>
      summarizeCodexPool([
        {
          provider: "codex-free",
          user: "free1@example.com",
          windows: [{ name: "30 days", used: 10, resetsAt: FUT_7D }],
        },
      ]),
    /no-seats/
  );
});

test("collectCodexPool uses HTTP primary and falls back to offline mirror files when HTTP fails", async () => {
  const dir = mkdtempSync(join(tmpdir(), "codex-pool-test-"));
  try {
    writeFileSync(
      join(dir, "providers.json"),
      JSON.stringify({
        providers: [
          {
            id: "codex",
            key: "must-never-be-read",
            accountCaps: { "beta@example.com": 90 },
            accountNames: { "alpha@example.com": "Alpha Business 工作區" },
          },
        ],
      })
    );
    writeFileSync(
      join(dir, "settings.json"),
      JSON.stringify({ codexNoCredits: ["beta@example.com"] })
    );
    writeFileSync(
      join(dir, "logins.json"),
      JSON.stringify([
        { agent: "codex", user: "gamma@example.com · TeamOrg", on: true, tokens: { secret: "w" } },
        { agent: "codex", user: "beta@example.com", on: true, order: 2, tokens: { secret: "x" } },
        { agent: "codex", user: "alpha@example.com", on: true, order: 1, tokens: { secret: "y" } },
        { agent: "codex", user: "disabled@example.com", order: 0, tokens: { secret: "z" } },
        { agent: "codex", user: "paused@example.com", on: true, paused: true, order: 3, tokens: { secret: "p" } },
        { agent: "plugin:codex-free", user: "free1@example.com", first: true, order: 1 },
      ])
    );
    writeFileSync(
      join(dir, "quotas.json"),
      JSON.stringify({
        "codex/alpha@example.com": {
          at: "2026-11-17T09:50:00Z",
          quota: {
            provider: "codex",
            plan: "promax",
            user: "alpha@example.com",
            readAt: "2026-11-17T09:50:00Z",
            windows: [{ name: "7 days", used: 12, resetsAt: FUT_7D }],
          },
        },
        "codex/beta@example.com": {
          at: "2026-11-17T09:50:00Z",
          quota: {
            provider: "codex",
            plan: "plus",
            user: "beta@example.com",
            readAt: "2026-11-17T09:50:00Z",
            windows: [
              { name: "5 hours", used: 30, resetsAt: FUT_5H },
              { name: "7 days", used: 90, resetsAt: FUT_7D },
            ],
          },
        },
        "codex/gamma@example.com · teamorg": {
          at: "2026-11-17T09:50:00Z",
          quota: {
            provider: "codex",
            plan: "team",
            user: "gamma@example.com · TeamOrg",
            readAt: "2026-11-17T09:50:00Z",
            windows: [{ name: "7 days", used: 40, resetsAt: FUT_7D }],
          },
        },
        "codex/disabled@example.com": {
          at: "2026-11-17T09:50:00Z",
          quota: {
            provider: "codex",
            plan: "plus",
            user: "disabled@example.com",
            readAt: "2026-11-17T09:50:00Z",
            windows: [{ name: "7 days", used: 0, resetsAt: FUT_7D }],
          },
        },
        "codex-free/free1@example.com": {
          at: "2026-11-17T09:50:00Z",
          quota: {
            provider: "codex-free",
            plan: "free",
            user: "free1@example.com",
            readAt: "2026-11-17T09:50:00Z",
            windows: [{ name: "30 days", used: 10, resetsAt: "2026-11-28T00:00:00Z" }],
          },
        },
      })
    );
    writeFileSync(
      join(dir, "served.json"),
      JSON.stringify({ "codex@alpha@example.com": "2026-11-17T09:58:00Z" })
    );

    const server = http.createServer((_req, res) => {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(
        JSON.stringify({
          data: [
            {
              provider: "codex",
              user: "alpha@example.com",
              plan: "promax",
              lastServedAt: "2026-11-17T09:59:00Z",
              windows: [{ name: "7 days", used: 5, resetsAt: FUT_7D }],
            },
            {
              provider: "codex",
              user: "disabled@example.com",
              plan: "plus",
              windows: [{ name: "7 days", used: 0, resetsAt: FUT_7D }],
            },
          ],
        })
      );
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = server.address().port;

    const httpOut = await collectCodexPool({
      endpoint: `http://127.0.0.1:${port}/v1/magpie/quotas?kept=1`,
      configDir: dir,
      nowMs: NOW_MS,
    });
    assert.equal(httpOut.source, "http");
    assert.equal(httpOut.total_seats, 1);
    assert.equal(httpOut.active.short_label, "Alpha Biz");
    assert.equal(httpOut.active.used_7d_pct, 5);

    await new Promise((resolve) => server.close(resolve));

    const mirrorOut = await collectCodexPool({
      endpoint: `http://127.0.0.1:${port}/v1/magpie/quotas?kept=1`,
      configDir: dir,
      nowMs: NOW_MS,
    });
    assert.equal(mirrorOut.source, "mirror");
    assert.equal(mirrorOut.total_seats, 3);
    assert.equal(mirrorOut.avail_seats, 2);
    assert.equal(mirrorOut.accounts[0].user, "alpha@example.com");
    assert.equal(mirrorOut.accounts[0].short_label, "Alpha Biz");
    assert.equal(mirrorOut.accounts[0].last_served_at, NOW_SEC - 120);
    assert.equal(mirrorOut.accounts[1].user, "beta@example.com");
    assert.equal(mirrorOut.accounts[1].usable, false);
    assert.equal(mirrorOut.accounts[2].user, "gamma@example.com · TeamOrg");
    assert.equal(mirrorOut.accounts[2].used_7d_pct, 40);
    assert.equal(mirrorOut.free_pool.total_seats, 1);
    assert.equal(mirrorOut.free_pool.avail_seats, 1);

    await assert.rejects(
      () =>
        collectCodexPool({
          endpoint: `http://127.0.0.1:${port}/v1/magpie/quotas?kept=1`,
          configDir: dir,
          nowMs: NOW_MS + 3601 * 1000,
        }),
      /stale-mirror/
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
