#!/usr/bin/env node
// Devin pool aggregate health -> ~/.claude/cache/vendor-devin-pool.{json,status}
// Reads live per-seat quotas from local Magpie (http://127.0.0.1:18417/v1/magpie/quotas)
// on the daemon's 60s cycle so wrapper.sh renders with zero network wait.
import { mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CACHE_DIR = join(homedir(), ".claude/cache");
const ENDPOINT = process.env.MAGPIE_QUOTAS_URL ?? "http://127.0.0.1:18417/v1/magpie/quotas";
const PROVIDERS_PATH =
  process.env.MAGPIE_PROVIDERS_PATH ?? join(homedir(), ".magpie-machine/home/.config/magpie/providers.json");

class Failure extends Error {}

function writeAtomic(name, payload) {
  mkdirSync(CACHE_DIR, { recursive: true });
  const path = join(CACHE_DIR, name);
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(payload), { mode: 0o600 });
  renameSync(tmp, path);
}

// The headline numbers are the user's own pool only; devin-friend is a friend's pool and
// would inflate "room" if mixed in. Every Devin pool is still listed in `pools` for the hover detail.
const OWN_PROVIDER = "devin-plugin";
// Devin Teams weekly allowance is 2x daily; the single non-Teams seat in the 61-seat pool
// introduces at most ~0.82 percentage points of pool-level approximation error.
const WEEK_TO_DAY_RATIO = 2;

export function parseAccountCaps(providersDoc) {
  const out = {};
  const list = Array.isArray(providersDoc?.providers) ? providersDoc.providers : [];
  for (const item of list) {
    const id = typeof item?.id === "string" ? item.id : "";
    const rawCaps = item?.accountCaps;
    if (!id || !rawCaps || typeof rawCaps !== "object") continue;
    const map = {};
    for (const [acct, val] of Object.entries(rawCaps)) {
      const n = Number(val);
      if (Number.isFinite(n) && n > 0 && n <= 100) {
        map[acct.trim().toLowerCase()] = n;
      }
    }
    out[id] = map;
  }
  return out;
}

function readAccountCaps(path) {
  try {
    return parseAccountCaps(JSON.parse(readFileSync(path, "utf8")));
  } catch {
    return {};
  }
}

function resolveSeatCap(seatCaps, user) {
  if (!seatCaps || typeof seatCaps !== "object") return 100;
  const key = String(user ?? "").trim().toLowerCase();
  return seatCaps[key] ?? seatCaps["*"] ?? 100;
}

function aggregate(rows, seatCaps = {}) {
  const totalSeats = rows.length;
  if (totalSeats === 0) return null;

  let sumEffRem1d = 0;
  let sumUsed7d = 0;
  let validSeats = 0;
  let reset1d = 0;
  let reset7d = 0;
  let availSeats = 0;
  let errorSeats = 0;
  let balanceUsd = "";

  for (const row of rows) {
    if (row?.error) {
      errorSeats++;
      // Unread seats contribute 0 confirmed remaining capacity so partial poll
      // failures cannot make a nearly full pool appear wide open.
      sumUsed7d += 100;
      continue;
    }
    if (!balanceUsd && typeof row?.balance === "string" && row.balance.startsWith("$")) {
      balanceUsd = row.balance.slice(1);
    }
    const wins = Array.isArray(row?.windows) ? row.windows : [];
    const w1 = wins.find((w) => w?.name === "1 day");
    const w7 = wins.find((w) => w?.name === "7 days");
    const u1 = Number(w1?.used);
    const u7 = Number(w7?.used);
    if (!w1 || !w7 || !Number.isFinite(u1) || !Number.isFinite(u7)) {
      sumUsed7d += 100;
      continue;
    }

    validSeats++;
    const t1 = Math.floor(Date.parse(w1.resetsAt ?? "") / 1000);
    if (Number.isFinite(t1) && t1 > reset1d) reset1d = t1;
    const t7 = Math.floor(Date.parse(w7.resetsAt ?? "") / 1000);
    if (Number.isFinite(t7) && t7 > reset7d) reset7d = t7;

    const cap = resolveSeatCap(seatCaps, row?.user);
    const effRem1d = Math.max(0, Math.min(cap - u1, WEEK_TO_DAY_RATIO * (cap - u7)));
    sumEffRem1d += effRem1d;
    sumUsed7d += Math.min(100, Math.max(0, u7));
    if (u1 < cap && u7 < cap) {
      availSeats++;
    }
  }

  if (validSeats === 0 || reset1d <= 0 || reset7d <= 0) return null;

  return {
    used_1d_pct: Math.round(100 - sumEffRem1d / totalSeats),
    reset_1d_at: reset1d,
    used_7d_pct: Math.round(sumUsed7d / totalSeats),
    reset_7d_at: reset7d,
    avail_seats: availSeats,
    total_seats: totalSeats,
    error_seats: errorSeats,
    balance_usd: balanceUsd,
  };
}

export function summarize(data, capsByProvider = {}) {
  const rows = Array.isArray(data) ? data.filter((r) => String(r?.provider ?? "").startsWith("devin")) : [];
  const own = rows.filter((r) => r?.provider === OWN_PROVIDER);
  if (own.length === 0) throw new Failure("no-seats");
  const head = aggregate(own, capsByProvider[OWN_PROVIDER]);
  if (!head) throw new Failure("invalid-response");
  const ids = [...new Set(rows.map((r) => r.provider))].sort((a, b) =>
    a === OWN_PROVIDER ? -1 : b === OWN_PROVIDER ? 1 : a.localeCompare(b)
  );
  const pools = ids
    .map((provider) => ({
      provider,
      stats: aggregate(
        rows.filter((r) => r.provider === provider),
        capsByProvider[provider]
      ),
    }))
    .filter((p) => p.stats)
    .map(({ provider, stats }) => ({ provider, ...stats }));
  return { ...head, pools };
}

async function fetchPoolHealth() {
  let res;
  try {
    res = await fetch(ENDPOINT, {
      headers: { Host: "127.0.0.1:18417" },
      signal: AbortSignal.timeout(5000),
    });
  } catch {
    throw new Failure("network-error");
  }
  if (!res.ok) throw new Failure(`http-${res.status}`);
  const body = await res.json().catch(() => null);
  return summarize(body?.data, readAccountCaps(PROVIDERS_PATH));
}

if (import.meta.url === `file://${process.argv[1]}`) try {
  const data = await fetchPoolHealth();
  writeAtomic("vendor-devin-pool.json", { fetched_at: Math.floor(Date.now() / 1000), data });
  try {
    unlinkSync(join(CACHE_DIR, "vendor-devin-pool.status"));
  } catch {}
} catch (err) {
  const reason = err instanceof Failure ? err.message : "unexpected";
  writeAtomic("vendor-devin-pool.status", { failed_at: Math.floor(Date.now() / 1000), reason });
}
