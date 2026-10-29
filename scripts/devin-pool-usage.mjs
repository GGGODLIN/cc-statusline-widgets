#!/usr/bin/env node
// Devin pool aggregate health -> ~/.claude/cache/vendor-devin-pool.{json,status}
// Reads live per-seat quotas from local Magpie (http://127.0.0.1:18417/v1/magpie/quotas)
// on the daemon's 60s cycle so wrapper.sh renders with zero network wait.
import { mkdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CACHE_DIR = join(homedir(), ".claude/cache");
const ENDPOINT = process.env.MAGPIE_QUOTAS_URL ?? "http://127.0.0.1:18417/v1/magpie/quotas";

class Failure extends Error {}

function writeAtomic(name, payload) {
  mkdirSync(CACHE_DIR, { recursive: true });
  const path = join(CACHE_DIR, name);
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(payload), { mode: 0o600 });
  renameSync(tmp, path);
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
  const rows = Array.isArray(body?.data)
    ? body.data.filter((r) => String(r?.provider ?? "").startsWith("devin"))
    : [];
  if (rows.length === 0) throw new Failure("no-seats");

  let sum1d = 0;
  let cnt1d = 0;
  let reset1d = 0;
  let sum7d = 0;
  let cnt7d = 0;
  let reset7d = 0;
  let availSeats = 0;
  let errorSeats = 0;
  let balanceUsd = "";

  for (const row of rows) {
    if (row?.error) {
      errorSeats++;
      continue;
    }
    if (!balanceUsd && typeof row?.balance === "string" && row.balance.startsWith("$")) {
      balanceUsd = row.balance.slice(1);
    }
    const wins = Array.isArray(row?.windows) ? row.windows : [];
    const w1 = wins.find((w) => w?.name === "1 day");
    const w7 = wins.find((w) => w?.name === "7 days");
    const u1 = Number(w1?.used ?? 0);
    const u7 = Number(w7?.used ?? 0);
    if (w1 && Number.isFinite(u1)) {
      sum1d += u1;
      cnt1d++;
      const t1 = Math.floor(Date.parse(w1.resetsAt ?? "") / 1000);
      if (Number.isFinite(t1) && t1 > reset1d) reset1d = t1;
    }
    if (w7 && Number.isFinite(u7)) {
      sum7d += u7;
      cnt7d++;
      const t7 = Math.floor(Date.parse(w7.resetsAt ?? "") / 1000);
      if (Number.isFinite(t7) && t7 > reset7d) reset7d = t7;
    }
    if (u1 < 100 && u7 < 100) {
      availSeats++;
    }
  }

  if (cnt1d === 0 || reset1d <= 0 || cnt7d === 0 || reset7d <= 0) {
    throw new Failure("invalid-response");
  }

  return {
    used_1d_pct: Math.round(sum1d / cnt1d),
    reset_1d_at: reset1d,
    used_7d_pct: Math.round(sum7d / cnt7d),
    reset_7d_at: reset7d,
    avail_seats: availSeats,
    total_seats: rows.length,
    error_seats: errorSeats,
    balance_usd: balanceUsd,
  };
}

try {
  const data = await fetchPoolHealth();
  writeAtomic("vendor-devin-pool.json", { fetched_at: Math.floor(Date.now() / 1000), data });
  try {
    unlinkSync(join(CACHE_DIR, "vendor-devin-pool.status"));
  } catch {}
} catch (err) {
  const reason = err instanceof Failure ? err.message : "unexpected";
  writeAtomic("vendor-devin-pool.status", { failed_at: Math.floor(Date.now() / 1000), reason });
}
