import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAccountCaps, summarize } from "../scripts/devin-pool-usage.mjs";

const seat = (provider, used1d, used7d, user = "seat@example.com · ORG") => ({
  provider,
  user,
  windows: [
    { name: "1 day", used: used1d, resetsAt: "2026-11-10T08:00:00Z" },
    { name: "7 days", used: used7d, resetsAt: "2026-11-15T08:00:00Z" },
  ],
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
