import { test } from "node:test";
import assert from "node:assert/strict";
import { summarize } from "../scripts/devin-pool-usage.mjs";

const seat = (provider, used1d, used7d) => ({
  provider,
  windows: [
    { name: "1 day", used: used1d, resetsAt: "2026-11-10T08:00:00Z" },
    { name: "7 days", used: used7d, resetsAt: "2026-11-15T08:00:00Z" },
  ],
});

test("headline numbers count only the own pool; every pool is listed apart", () => {
  const out = summarize([
    seat("devin-plugin", 10, 20),
    seat("devin-plugin", 30, 100),
    seat("devin-friend", 0, 0),
    seat("cline", 90, 90),
  ]);
  assert.equal(out.total_seats, 2);
  assert.equal(out.avail_seats, 1);
  assert.equal(out.used_7d_pct, 60);
  assert.deepEqual(
    out.pools.map((p) => [p.provider, p.total_seats, p.used_7d_pct]),
    [
      ["devin-plugin", 2, 60],
      ["devin-friend", 1, 0],
    ]
  );
});

test("no own seats is a failure even when a friend pool exists", () => {
  assert.throws(() => summarize([seat("devin-friend", 0, 0)]), /no-seats/);
});
