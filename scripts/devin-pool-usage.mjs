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
const LOGINS_PATH =
  process.env.MAGPIE_LOGINS_PATH ?? join(homedir(), ".magpie-machine/home/.config/magpie/logins.json");
const PLUGIN_AUTH_PATH =
  process.env.MAGPIE_PLUGIN_AUTH_PATH ?? join(homedir(), ".magpie-machine/home/.config/magpie/plugin-auth.json");

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
// Devin Teams weekly allowance is 2x daily.
const WEEK_TO_DAY_RATIO = 2;

// Magpie keeps a plugin's logins under "plugin:<plugin id>", and devin-plugin's plugin id is "devin".
const LOGIN_AGENT = { "devin-plugin": "plugin:devin" };
const seatKey = (provider, user) =>
  `${LOGIN_AGENT[provider] ?? `plugin:${provider}`}\n${String(user ?? "").trim().toLowerCase()}`;

// Magpie serializes savedLogin.On with omitempty, so seats turned off omit `on` rather than writing false.
function isLoginRoutable(entry) {
  if (!entry || typeof entry !== "object") return false;
  if (entry.paused === true || entry.lapsed === true || entry.hidden === true) return false;
  return entry.on === true || entry.active === true;
}

// A seat turned off in the pool stays signed in, so /v1/magpie/quotas still lists it; counting it
// shows a seat routing never uses as free room (My Team, 2026-11-17: 53/61 shown, 52/60 real).
// A seat with no login record is kept, so an unreadable logins.json cannot empty the pool.
export function parseOffSeats(rawLogins) {
  const list = Array.isArray(rawLogins)
    ? rawLogins
    : Array.isArray(rawLogins?.logins)
      ? rawLogins.logins
      : [];
  const routable = new Set();
  const off = new Set();
  for (const l of list) {
    if (typeof l?.agent !== "string" || typeof l?.user !== "string") continue;
    const key = `${l.agent}\n${l.user.trim().toLowerCase()}`;
    if (isLoginRoutable(l)) {
      routable.add(key);
    } else {
      off.add(key);
    }
  }
  for (const key of routable) off.delete(key);
  return off;
}

function readOffSeats(path) {
  try {
    return parseOffSeats(JSON.parse(readFileSync(path, "utf8")));
  } catch {
    return new Set();
  }
}

// Read ONLY metadata.plan and metadata.email — never read, log, or emit keys/tokens.
export function parsePluginAuthPlans(authDoc) {
  const plans = {};
  if (!authDoc || typeof authDoc !== "object" || Array.isArray(authDoc)) return plans;
  for (const [k, entry] of Object.entries(authDoc)) {
    const base = String(k).split("#")[0];
    if (!base.startsWith("devin")) continue;
    const provider = base === "devin" ? "devin-plugin" : base;
    const email = typeof entry?.metadata?.email === "string" ? entry.metadata.email.trim().toLowerCase() : "";
    const plan = typeof entry?.metadata?.plan === "string" ? entry.metadata.plan.trim() : "";
    if (!email || !plan) continue;
    if (!plans[provider]) plans[provider] = {};
    plans[provider][email] = plan;
  }
  return plans;
}

function readPluginAuthPlans(path) {
  try {
    return parsePluginAuthPlans(JSON.parse(readFileSync(path, "utf8")));
  } catch {
    return {};
  }
}

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

export function parseAccountNames(providersDoc) {
  const out = {};
  const list = Array.isArray(providersDoc?.providers) ? providersDoc.providers : [];
  for (const item of list) {
    const id = typeof item?.id === "string" ? item.id : "";
    const rawNames = item?.accountNames;
    if (!id || !rawNames || typeof rawNames !== "object") continue;
    const map = {};
    for (const [acct, val] of Object.entries(rawNames)) {
      if (typeof val === "string" && val.trim()) {
        map[acct.trim().toLowerCase()] = val.trim();
      }
    }
    out[id] = map;
  }
  return out;
}

function readProvidersExtras(path) {
  try {
    const doc = JSON.parse(readFileSync(path, "utf8"));
    return {
      capsByProvider: parseAccountCaps(doc),
      namesByProvider: parseAccountNames(doc),
    };
  } catch {
    return { capsByProvider: {}, namesByProvider: {} };
  }
}

function resolveSeatCap(seatCaps, user) {
  if (!seatCaps || typeof seatCaps !== "object") return 100;
  const key = String(user ?? "").trim().toLowerCase();
  return seatCaps[key] ?? seatCaps["*"] ?? 100;
}

function sanitizeLabel(text) {
  return String(text ?? "").replace(/[:|\r\n\x00-\x1f\x7f]/g, "");
}

function sliceChars(text, max) {
  return Array.from(text).slice(0, max).join("");
}

export function shortLabel(user, alias) {
  const rawAlias = typeof alias === "string" ? alias.trim() : "";
  if (rawAlias) {
    const stripped = sanitizeLabel(rawAlias);
    if (stripped) return sliceChars(stripped, 16);
  }
  const rawUser = String(user ?? "");
  const dotIdx = rawUser.indexOf("·");
  const before = dotIdx >= 0 ? rawUser.slice(0, dotIdx).trim() : rawUser.trim();
  const localRaw = sanitizeLabel(before.split("@")[0].trim());
  const plusIdx = localRaw.indexOf("+");
  const local =
    plusIdx >= 0 && localRaw.slice(plusIdx + 1).trim()
      ? localRaw.slice(plusIdx + 1).trim()
      : localRaw;
  const out = sliceChars(local, 16);
  return out || "devin";
}

function parseEpochSec(val) {
  if (typeof val === "number") {
    if (!Number.isFinite(val) || val <= 0) return null;
    return Math.floor(val > 1e12 ? val / 1000 : val);
  }
  if (typeof val === "string") {
    const s = val.trim();
    if (!s) return null;
    const ms = Date.parse(s);
    return Number.isFinite(ms) && ms > 0 ? Math.floor(ms / 1000) : null;
  }
  return null;
}

function aggregate(rows, seatCaps = {}, plansMap = {}, namesMap = {}) {
  const totalSeats = rows.length;
  if (totalSeats === 0) return null;

  let teamsTotal = 0;
  let teamsAvail = 0;
  let teamsError = 0;
  let teamsValid = 0;
  let sumTeamsEffRem1d = 0;
  let sumTeamsUsed7d = 0;
  let teamsReset1d = 0;
  let teamsReset7d = 0;

  let maxTotal = 0;
  let maxAvail = 0;
  let maxError = 0;
  let maxValid = 0;
  let sumMaxUsed7d = 0;
  let maxReset7d = 0;

  let errorSeats = 0;
  let balanceUsd = "";
  const rawAccounts = [];

  for (const row of rows) {
    const user = String(row?.user ?? "");
    const userKey = user.trim().toLowerCase();
    const rowPlan = typeof row?.plan === "string" && row.plan.trim() ? row.plan.trim() : null;
    const plan = rowPlan ?? plansMap[userKey] ?? null;
    const rowAlias = typeof row?.alias === "string" && row.alias.trim() ? row.alias.trim() : null;
    const alias = rowAlias ?? namesMap[userKey] ?? null;
    const baseLabel = shortLabel(user, alias);
    const until = typeof row?.until === "string" && row.until.trim() ? row.until.trim() : null;
    const error = row?.error ? String(row.error) : null;
    const held = Boolean(row?.held);

    if (!error && !balanceUsd && typeof row?.balance === "string" && row.balance.startsWith("$")) {
      balanceUsd = row.balance.slice(1);
    }

    const wins = Array.isArray(row?.windows) ? row.windows : [];
    const w1 = wins.find((w) => w?.name === "1 day");
    const w7 = wins.find((w) => w?.name === "7 days");
    const u1 = Number(w1?.used);
    const u7 = Number(w7?.used);
    const hasW1 = Boolean(w1) && Number.isFinite(u1);
    const hasW7 = Boolean(w7) && Number.isFinite(u7);

    const isMax = (plan !== null && /max/i.test(plan)) || (!w1 && Boolean(w7));
    const tier = isMax ? "max" : "teams";

    const reset1dAt = !error && w1 ? parseEpochSec(w1.resetsAt) : null;
    const reset7dAt = !error && w7 ? parseEpochSec(w7.resetsAt) : null;
    const cap = resolveSeatCap(seatCaps, user);

    let avail = false;
    if (tier === "max") {
      maxTotal++;
      if (error) {
        errorSeats++;
        maxError++;
        sumMaxUsed7d += 100;
      } else if (!hasW7) {
        sumMaxUsed7d += 100;
      } else {
        maxValid++;
        if (reset7dAt !== null && reset7dAt > maxReset7d) maxReset7d = reset7dAt;
        sumMaxUsed7d += Math.min(100, Math.max(0, u7));
        if (!held && u7 < cap) {
          maxAvail++;
          avail = true;
        }
      }
    } else {
      teamsTotal++;
      if (error) {
        errorSeats++;
        teamsError++;
        sumTeamsUsed7d += 100;
      } else if (!hasW1 || !hasW7) {
        sumTeamsUsed7d += 100;
      } else {
        teamsValid++;
        if (reset1dAt !== null && reset1dAt > teamsReset1d) teamsReset1d = reset1dAt;
        if (reset7dAt !== null && reset7dAt > teamsReset7d) teamsReset7d = reset7dAt;
        const effRem1d = Math.max(0, Math.min(cap - u1, WEEK_TO_DAY_RATIO * (cap - u7)));
        sumTeamsEffRem1d += effRem1d;
        sumTeamsUsed7d += Math.min(100, Math.max(0, u7));
        if (!held && u1 < cap && u7 < cap) {
          teamsAvail++;
          avail = true;
        }
      }
    }

    rawAccounts.push({
      user,
      baseLabel,
      plan,
      tier,
      until,
      used_1d_pct: !error && hasW1 && tier !== "max" ? Math.min(100, Math.max(0, Math.round(u1))) : null,
      reset_1d_at: !error && tier !== "max" ? reset1dAt : null,
      used_7d_pct: !error && hasW7 ? Math.min(100, Math.max(0, Math.round(u7))) : null,
      reset_7d_at: !error ? reset7dAt : null,
      available: avail,
      error,
    });
  }

  const validSeats = teamsValid + maxValid;
  const overallReset7d = Math.max(teamsReset7d, maxReset7d);
  if (validSeats === 0 || overallReset7d <= 0) return null;
  if (teamsValid > 0 && teamsReset1d <= 0) return null;

  const labelCounts = new Map();
  for (const a of rawAccounts) {
    labelCounts.set(a.baseLabel, (labelCounts.get(a.baseLabel) ?? 0) + 1);
  }
  const accounts = rawAccounts
    .map((a) => {
      let short = a.baseLabel;
      if ((labelCounts.get(a.baseLabel) ?? 0) > 1) {
        const dotIdx = a.user.indexOf("·");
        const org = dotIdx >= 0 ? sanitizeLabel(a.user.slice(dotIdx + 1).trim()) : "";
        if (org) short = sliceChars(`${a.baseLabel}·${sliceChars(org, 4)}`, 16);
      }
      return {
        user: a.user,
        short_label: short,
        plan: a.plan,
        tier: a.tier,
        until: a.until,
        used_1d_pct: a.used_1d_pct,
        reset_1d_at: a.reset_1d_at,
        used_7d_pct: a.used_7d_pct,
        reset_7d_at: a.reset_7d_at,
        available: a.available,
        error: a.error,
      };
    })
    .sort((a, b) => (a.tier === b.tier ? 0 : a.tier === "teams" ? -1 : 1));

  const teamsTier =
    teamsTotal > 0
      ? {
          used_1d_pct: teamsValid > 0 ? Math.round(100 - sumTeamsEffRem1d / teamsTotal) : null,
          reset_1d_at: teamsReset1d > 0 ? teamsReset1d : null,
          used_7d_pct: Math.round(sumTeamsUsed7d / teamsTotal),
          reset_7d_at: teamsReset7d > 0 ? teamsReset7d : null,
          avail_seats: teamsAvail,
          total_seats: teamsTotal,
          error_seats: teamsError,
        }
      : null;

  const maxTier =
    maxTotal > 0
      ? {
          used_7d_pct: maxValid > 0 ? Math.round(sumMaxUsed7d / maxTotal) : null,
          reset_7d_at: maxReset7d > 0 ? maxReset7d : null,
          avail_seats: maxAvail,
          total_seats: maxTotal,
          error_seats: maxError,
        }
      : null;

  const used1dPct = teamsTier ? teamsTier.used_1d_pct : null;
  const reset1dAt = teamsTier ? teamsTier.reset_1d_at : null;
  const used7dPct =
    teamsTotal === 0
      ? maxTier.used_7d_pct
      : Math.round((sumTeamsUsed7d + sumMaxUsed7d) / totalSeats);

  return {
    used_1d_pct: used1dPct,
    reset_1d_at: reset1dAt,
    used_7d_pct: used7dPct,
    reset_7d_at: overallReset7d,
    avail_seats: teamsAvail + maxAvail,
    total_seats: totalSeats,
    error_seats: errorSeats,
    balance_usd: balanceUsd,
    tiers: {
      teams: teamsTier,
      max: maxTier,
    },
    accounts,
  };
}

export function summarize(data, capsByProvider = {}, offSeats = new Set(), plansByProvider = {}, namesByProvider = {}) {
  const rows = Array.isArray(data)
    ? data.filter(
        (r) => String(r?.provider ?? "").startsWith("devin") && !offSeats.has(seatKey(r.provider, r?.user))
      )
    : [];
  const own = rows.filter((r) => r?.provider === OWN_PROVIDER);
  if (own.length === 0) throw new Failure("no-seats");
  const head = aggregate(
    own,
    capsByProvider[OWN_PROVIDER],
    plansByProvider[OWN_PROVIDER],
    namesByProvider[OWN_PROVIDER]
  );
  if (!head) throw new Failure("invalid-response");
  const ids = [...new Set(rows.map((r) => r.provider))].sort((a, b) =>
    a === OWN_PROVIDER ? -1 : b === OWN_PROVIDER ? 1 : a.localeCompare(b)
  );
  const pools = ids
    .map((provider) => ({
      provider,
      stats: aggregate(
        rows.filter((r) => r.provider === provider),
        capsByProvider[provider],
        plansByProvider[provider],
        namesByProvider[provider]
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
  const { capsByProvider, namesByProvider } = readProvidersExtras(PROVIDERS_PATH);
  return summarize(
    body?.data,
    capsByProvider,
    readOffSeats(LOGINS_PATH),
    readPluginAuthPlans(PLUGIN_AUTH_PATH),
    namesByProvider
  );
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
