import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseUsageResponse, runGrokBotSync } from "../scripts/grok-bot-usage.mjs";

test("parseUsageResponse accepts valid response and handles includedLimitZero", () => {
  assert.deepEqual(
    parseUsageResponse({ usagePercent: 42.5, nextResetTimestampUtc: "2026-11-29T00:00:00Z" }),
    { used_percent: 42.5, reset_at: Math.floor(Date.parse("2026-11-29T00:00:00Z") / 1000) }
  );
  assert.equal(parseUsageResponse({ includedLimitZero: true }), null);
});

test("parseUsageResponse rejects out-of-range used, non-numeric used, and non-string/invalid timestamp", () => {
  for (const bad of [
    null,
    [],
    { usagePercent: 100.1, nextResetTimestampUtc: "2026-11-29T00:00:00Z" },
    { usagePercent: -0.1, nextResetTimestampUtc: "2026-11-29T00:00:00Z" },
    { usagePercent: "42", nextResetTimestampUtc: "2026-11-29T00:00:00Z" },
    { usagePercent: true, nextResetTimestampUtc: "2026-11-29T00:00:00Z" },
    { usagePercent: Number.NaN, nextResetTimestampUtc: "2026-11-29T00:00:00Z" },
    { usagePercent: 10, nextResetTimestampUtc: 1796000000 },
    { usagePercent: 10, nextResetTimestampUtc: null },
    { usagePercent: 10, nextResetTimestampUtc: "   " },
    { usagePercent: 10, nextResetTimestampUtc: "not-a-date" },
  ]) {
    assert.throws(() => parseUsageResponse(bad), /invalid-response/);
  }
});

test("runGrokBotSync writes cache and removes stale .status on recovery", async () => {
  const dir = mkdtempSync(join(tmpdir(), "grok-bot-test-"));
  try {
    const cacheDir = join(dir, "cache");
    const samplesPath = join(dir, "samples.jsonl");
    writeFileSync(samplesPath, "{}\n");
    const statusPath = join(cacheDir, "vendor-grok-bot-local.status");
    const jsonPath = join(cacheDir, "vendor-grok-bot-local.json");

    // Seed an error first via failing fetchUsageFn after a previous json exists
    await runGrokBotSync({
      cacheDir,
      samplesPath,
      readTokenFn: () => "tok",
      fetchUsageFn: async () => ({ used_percent: 12, reset_at: 1800000000 }),
    });
    assert.equal(existsSync(jsonPath), true);

    writeFileSync(statusPath, JSON.stringify({ failed_at: 1700000000, reason: "http-401" }));
    assert.equal(existsSync(statusPath), true);

    const status = await runGrokBotSync({
      cacheDir,
      samplesPath,
      readTokenFn: () => "tok",
      fetchUsageFn: async () => ({ used_percent: 25, reset_at: 1800000500 }),
    });
    assert.equal(status, "ok");
    assert.equal(existsSync(statusPath), false);
    const written = JSON.parse(readFileSync(jsonPath, "utf8"));
    assert.deepEqual(written.data, { used_percent: 25, reset_at: 1800000500 });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
