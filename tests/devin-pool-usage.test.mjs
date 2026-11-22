import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAccountCaps, parseOffSeats, parsePluginAuthPlans, summarize } from "../scripts/devin-pool-usage.mjs";

const seat = (provider, used1d, used7d, user = "seat@example.com · ORG", extra = {}) => ({
  provider,
  user,
  windows: [
    { name: "1 day", used: used1d, resetsAt: "2026-11-10T08:00:00Z" },
    { name: "7 days", used: used7d, resetsAt: "2026-11-15T08:00:00Z" },
  ],
  ...extra,
});

const maxSeat = (provider, used7d, user = "max@example.com · My Team", extra = {}) => ({
  provider,
  user,
  windows: [{ name: "7 days", used: used7d, resetsAt: "2026-11-22T08:00:00Z" }],
  ...extra,
});

test("headline numbers count only the own pool; weekly-exhausted seat caps effective 1d at 100%", () => {
  const out = summarize([
    seat("devin-plugin", 10, 20),
    seat("devin-plugin", 30, 100),
    seat("devin-friend", 0, 0),
    seat("cline", 90, 90),
  ]);
  assert.equal(out.total_seats, 2);
  assert.equal(out.avail_seats, 1);
  assert.equal(out.used_1d_pct, 55);
  assert.equal(out.used_7d_pct, 60);
  assert.deepEqual(
    out.pools.map((p) => [p.provider, p.total_seats, p.used_7d_pct]),
    [
      ["devin-plugin", 2, 60],
      ["devin-friend", 1, 0],
    ]
  );
});

test("weekly remaining bounds daily effective capacity by 2x ratio", () => {
  const out = summarize([
    seat("devin-plugin", 0, 90),
    seat("devin-plugin", 100, 50),
  ]);
  // Seat 1: min(100, 2*10) = 20% eff rem (80% eff used); Seat 2: 0% eff rem (100% eff used) -> avg 90%
  assert.equal(out.used_1d_pct, 90);
  assert.equal(out.avail_seats, 1);
});

test("accountCaps (case-insensitive) bound both effective 1d capacity and avail_seats", () => {
  const caps = parseAccountCaps({
    providers: [{ id: "devin-friend", accountCaps: { "a@example.com · org": 95, "b@example.com · org": 95 } }],
  });
  const out = summarize(
    [
      seat("devin-plugin", 0, 0),
      seat("devin-friend", 0, 95, "a@example.com · ORG"),
      seat("devin-friend", 88, 44, "b@example.com · ORG"),
    ],
    caps
  );
  const friend = out.pools.find((p) => p.provider === "devin-friend");
  // Seat a: cap 95, u7=95 -> effRem=0, not avail; Seat b: min(95-88, 2*(95-44))=7 -> avg effRem=3.5 -> used=97%
  assert.equal(friend.avail_seats, 1);
  assert.equal(friend.used_1d_pct, 97);
});

test("partial poll errors keep total_seats denominator as conservative lower bound; all errors fail", () => {
  const out = summarize([
    seat("devin-plugin", 0, 0),
    { provider: "devin-plugin", error: "429 Too Many Requests" },
  ]);
  assert.equal(out.total_seats, 2);
  assert.equal(out.error_seats, 1);
  assert.equal(out.avail_seats, 1);
  assert.equal(out.used_1d_pct, 50);
  assert.equal(out.used_7d_pct, 50);

  assert.throws(
    () => summarize([{ provider: "devin-plugin", error: "429 Too Many Requests" }]),
    /invalid-response/
  );
});

test("no own seats is a failure even when a friend pool exists", () => {
  assert.throws(() => summarize([seat("devin-friend", 0, 0)]), /no-seats/);
});

test("parseOffSeats excludes logins where neither on nor active is true, normalizes case, and drops paused/lapsed/hidden", () => {
  const off = parseOffSeats({
    logins: [
      { agent: "plugin:devin", user: "Enabled@Example.com · ORG", on: true },
      { agent: "plugin:devin", user: "disabled@example.com · ORG" },
      { agent: "plugin:devin", user: "paused@example.com · ORG", on: true, paused: true },
      { agent: "plugin:devin", user: "lapsed@example.com · ORG", active: true, lapsed: true },
      { agent: "plugin:devin", user: "hidden@example.com · ORG", on: true, hidden: true },
    ],
  });
  const out = summarize(
    [
      seat("devin-plugin", 10, 20, "enabled@example.com · ORG"),
      seat("devin-plugin", 0, 0, "disabled@example.com · ORG"),
      seat("devin-plugin", 0, 0, "paused@example.com · ORG"),
      seat("devin-plugin", 0, 0, "lapsed@example.com · ORG"),
      seat("devin-plugin", 0, 0, "hidden@example.com · ORG"),
    ],
    {},
    off
  );
  assert.equal(out.total_seats, 1);
  assert.equal(out.avail_seats, 1);
});

test("mixed 3 Teams + 1 Max never penalizes Max seat and emits tier and account breakdowns", () => {
  const plans = parsePluginAuthPlans({
    devin: { key: "SECRET_SHOULD_BE_IGNORED", metadata: { email: "philiplin@calyxtechs.com · GGGODLIN", plan: "Devin Teams" } },
    "devin#01": { key: "SECRET_2", metadata: { email: "qwe70301@gmail.com · GGGODLIN", plan: "Devin Teams" } },
    "devin#02": { key: "SECRET_3", metadata: { email: "qwe70301+alec.yeung@gmail.com · GGGODLIN", plan: "Devin Teams" } },
    "devin#max": { key: "SECRET_4", metadata: { email: "qwe70302@gmail.com · My Team", plan: "Devin Max" } },
  });
  const out = summarize(
    [
      seat("devin-plugin", 0, 52, "qwe70301@gmail.com · GGGODLIN", { until: "2026-11-29T03:58:21Z" }),
      seat("devin-plugin", 17, 8, "qwe70301+alec.yeung@gmail.com · GGGODLIN", { until: "2026-11-29T03:58:21Z" }),
      seat("devin-plugin", 0, 73, "philiplin@calyxtechs.com · GGGODLIN", { until: "2026-11-29T03:58:21Z" }),
      maxSeat("devin-plugin", 0, "qwe70302@gmail.com · My Team", { until: "2026-12-21T00:57:39Z" }),
    ],
    {},
    new Set(),
    plans
  );

  // Teams effRem1d = min(100,96) + min(83,184) + min(100,54) = 96 + 83 + 54 = 233 -> avg rem 77.67 -> 22% used
  assert.equal(out.avail_seats, 4);
  assert.equal(out.total_seats, 4);
  assert.equal(out.used_1d_pct, 22);
  assert.equal(out.used_7d_pct, 33);
  assert.equal(out.tiers.teams.used_1d_pct, 22);
  assert.equal(out.tiers.teams.used_7d_pct, 44);
  assert.equal(out.tiers.teams.avail_seats, 3);
  assert.equal(out.tiers.teams.total_seats, 3);
  assert.equal(out.tiers.max.used_7d_pct, 0);
  assert.equal(out.tiers.max.avail_seats, 1);
  assert.equal(out.tiers.max.total_seats, 1);
  assert.equal(out.accounts.length, 4);
  assert.deepEqual(
    out.accounts.map((a) => [a.short_label, a.tier, a.plan, a.available, a.used_1d_pct, a.used_7d_pct]),
    [
      ["qwe70301", "teams", "Devin Teams", true, 0, 52],
      ["alec.yeung", "teams", "Devin Teams", true, 17, 8],
      ["philiplin", "teams", "Devin Teams", true, 0, 73],
      ["qwe70302", "max", "Devin Max", true, null, 0],
    ]
  );
  assert.equal(JSON.stringify(out).includes("SECRET_"), false);
});

test("post-11/29 Max-only 7d-only mode emits null 1d fields without failing invalid-response", () => {
  const plans = parsePluginAuthPlans({
    "devin#max": { metadata: { email: "qwe70302@gmail.com · My Team", plan: "Devin Max" } },
  });
  const availOut = summarize(
    [maxSeat("devin-plugin", 12, "qwe70302@gmail.com · My Team", { until: "2026-12-21T00:57:39Z" })],
    {},
    new Set(),
    plans
  );
  assert.equal(availOut.used_1d_pct, null);
  assert.equal(availOut.reset_1d_at, null);
  assert.equal(availOut.used_7d_pct, 12);
  assert.equal(availOut.avail_seats, 1);
  assert.equal(availOut.total_seats, 1);
  assert.equal(availOut.tiers.teams, null);
  assert.equal(availOut.tiers.max.used_7d_pct, 12);
  assert.equal(availOut.tiers.max.avail_seats, 1);

  const fullOut = summarize(
    [maxSeat("devin-plugin", 100, "qwe70302@gmail.com · My Team")],
    {},
    new Set(),
    plans
  );
  assert.equal(fullOut.avail_seats, 0);
  assert.equal(fullOut.used_7d_pct, 100);
});

test("M-CS-D01..D03: parseOffSeats handles top-level array, active-only logins, and re-enabled duplicates", () => {
  const off = parseOffSeats([
    { agent: "plugin:devin", user: "active@example.com · ORG", active: true },
    { agent: "plugin:devin", user: "off@example.com · ORG" },
    { agent: "plugin:devin", user: "dup@example.com · ORG" },
    { agent: "plugin:devin", user: "dup@example.com · ORG", on: true },
  ]);
  assert.equal(off.has("plugin:devin\nactive@example.com · org"), false);
  assert.equal(off.has("plugin:devin\noff@example.com · org"), true);
  assert.equal(off.has("plugin:devin\ndup@example.com · org"), false);
});

test("M-CS-D04..D08: wildcard caps, sanitized balance, 7d-only max inference, held seats, and teams-first sorting", () => {
  const caps = parseAccountCaps({
    providers: [{ id: "devin-plugin", accountCaps: { "*": 80 } }],
  });
  const out = summarize(
    [
      maxSeat("devin-plugin", 10, "max1@example.com · TeamA"),
      maxSeat("devin-plugin", 10, "maxheld@example.com · TeamA", { held: true }),
      seat("devin-plugin", 10, 20, "teams1@example.com · TeamA", { balance: "$123.45\n\x07" }),
      seat("devin-plugin", 80, 10, "teamscapped@example.com · TeamA"),
      seat("devin-plugin", 10, 10, "teamsheld@example.com · TeamA", { held: true }),
    ],
    caps
  );

  assert.equal(out.balance_usd, "123.45");
  assert.equal(out.tiers.max.total_seats, 2);
  assert.equal(out.tiers.max.avail_seats, 1);
  assert.equal(out.tiers.teams.total_seats, 3);
  assert.equal(out.tiers.teams.avail_seats, 1);
  assert.equal(out.avail_seats, 2);
  assert.deepEqual(
    out.accounts.map((a) => a.tier),
    ["teams", "teams", "teams", "max", "max"]
  );
  assert.equal(out.accounts[2].available, false);
  assert.equal(out.accounts[4].available, false);
});

test("CS-08: rejects non-numeric/boolean used and caps, clamps negative used >= 0", () => {
  const caps = parseAccountCaps({
    providers: [{ id: "devin-plugin", accountCaps: { "*": true, "a@example.com": false } }],
  });
  assert.equal(caps["devin-plugin"]["*"], undefined);
  assert.equal(caps["devin-plugin"]["a@example.com"], undefined);

  const negOnly = summarize([seat("devin-plugin", -20, -10, "neg@example.com · ORG")], caps);
  assert.equal(negOnly.used_1d_pct, 0);
  assert.equal(negOnly.used_7d_pct, 0);
  assert.equal(negOnly.tiers.teams.used_1d_pct, 0);
  assert.equal(negOnly.avail_seats, 1);

  const out = summarize(
    [
      seat("devin-plugin", -20, -10, "neg@example.com · ORG"),
      seat("devin-plugin", null, 10, "nullused@example.com · ORG"),
      seat("devin-plugin", "", 10, "emptyused@example.com · ORG"),
      seat("devin-plugin", false, 10, "boolused@example.com · ORG"),
    ],
    caps
  );

  assert.equal(out.avail_seats, 1);
  assert.equal(out.accounts[0].used_1d_pct, 0);
  assert.equal(out.accounts[0].used_7d_pct, 0);
  assert.equal(out.accounts[0].available, true);
  assert.equal(out.accounts[1].used_1d_pct, null);
  assert.equal(out.accounts[1].available, false);
  assert.equal(out.accounts[2].used_1d_pct, null);
  assert.equal(out.accounts[2].available, false);
  assert.equal(out.accounts[3].used_1d_pct, null);
  assert.equal(out.accounts[3].available, false);
});
