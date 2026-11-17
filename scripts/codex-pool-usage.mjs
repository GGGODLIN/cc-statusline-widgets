#!/usr/bin/env node
// Codex/GPT pool active-account & seat health -> ~/.claude/cache/vendor-codex-pool.{json,status}
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CACHE_DIR = join(homedir(), ".claude/cache");
const ENDPOINT = process.env.MAGPIE_QUOTAS_URL ?? "http://127.0.0.1:18417/v1/magpie/quotas?kept=1";
const CONFIG_DIR = process.env.MAGPIE_CONFIG_DIR ?? join(homedir(), ".magpie-machine/home/.config/magpie");
const MIRROR_MAX_AGE_MS = 3600 * 1000;

class Failure extends Error {}

function writeAtomic(name, payload) {
  mkdirSync(CACHE_DIR, { recursive: true });
  const path = join(CACHE_DIR, name);
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(payload), { mode: 0o600 });
  renameSync(tmp, path);
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
    const stripped = sanitizeLabel(
      rawAlias
        .replace(/\s*工作區$/u, "")
        .replace(/Business/gi, "Biz")
        .trim()
    );
    if (stripped) return sliceChars(stripped, 14);
  }
  const rawUser = String(user ?? "");
  const dotIdx = rawUser.indexOf("·");
  const before = dotIdx >= 0 ? rawUser.slice(0, dotIdx).trim() : rawUser.trim();
  const after = dotIdx >= 0 ? rawUser.slice(dotIdx + 1).trim() : "";
  const local = sanitizeLabel(before.split("@")[0].trim());
  const suffixClean = sanitizeLabel(after);
  const combined =
    dotIdx >= 0 && suffixClean
      ? `${local}·${sliceChars(suffixClean, 4)}`
      : local;
  const out = sliceChars(combined, 14);
  return out ? out : "codex";
}

function parseTimestampMs(val) {
  if (typeof val === "number") {
    if (!Number.isFinite(val) || val <= 0) return null;
    return val > 1e12 ? val : val * 1000;
  }
  if (typeof val === "string") {
    const trimmed = val.trim();
    if (!trimmed) return null;
    const num = Number(trimmed);
    if (Number.isFinite(num)) {
      if (num <= 0) return null;
      return num > 1e12 ? num : num * 1000;
    }
    const ms = Date.parse(trimmed);
    return Number.isFinite(ms) && ms > 0 ? ms : null;
  }
  return null;
}

function parseBalanceNumber(balance) {
  if (typeof balance === "number") return Number.isFinite(balance) ? balance : null;
  if (typeof balance !== "string") return null;
  const m = balance.match(/[-+]?(?:\d+\.?\d*|\.\d+)/);
  if (!m) return null;
  const n = Number(m[0]);
  return Number.isFinite(n) ? n : null;
}

function parseWindow(windows, name, nowMs) {
  const win = windows.find((w) => w && w.lane !== "images" && w.name === name);
  if (!win) return { used: null, resetAt: null };
  const resetMs = parseTimestampMs(win.resetsAt);
  if (resetMs !== null && resetMs <= nowMs) {
    return { used: 0, resetAt: null };
  }
  const resetAt = resetMs !== null ? Math.floor(resetMs / 1000) : null;
  if (win.used !== null && win.used !== undefined && Number.isFinite(Number(win.used))) {
    const used = Math.min(100, Math.max(0, Math.round(Number(win.used))));
    return { used, resetAt };
  }
  return { used: null, resetAt };
}

const CODEX_LOGIN_AGENT = {
  codex: "codex",
  "codex-free": "plugin:codex-free",
  "plugin:codex-free": "plugin:codex-free",
};

function codexSeatKey(agentOrProvider, user) {
  const agent = CODEX_LOGIN_AGENT[String(agentOrProvider ?? "")] ?? String(agentOrProvider ?? "");
  return `${agent}\n${String(user ?? "").trim().toLowerCase()}`;
}

// Magpie serializes savedLogin.On with omitempty, so seats turned off omit `on` rather than writing false.
function isLoginRoutable(entry) {
  if (!entry || typeof entry !== "object") return false;
  if (entry.paused === true || entry.lapsed === true || entry.hidden === true) return false;
  return entry.on === true || entry.active === true || entry.first === true;
}

export function parseOffCodexSeats(rawLogins) {
  const list = Array.isArray(rawLogins)
    ? rawLogins
    : Array.isArray(rawLogins?.logins)
      ? rawLogins.logins
      : [];
  const routable = new Set();
  const off = new Set();
  for (const l of list) {
    if (typeof l?.agent !== "string" || typeof l?.user !== "string") continue;
    if (l.agent !== "codex" && l.agent !== "plugin:codex-free") continue;
    const key = codexSeatKey(l.agent, l.user);
    if (isLoginRoutable(l)) {
      routable.add(key);
    } else {
      off.add(key);
    }
  }
  for (const key of routable) off.delete(key);
  return off;
}

function normalizeMap(obj, coerce) {
  const out = {};
  if (!obj || typeof obj !== "object") return out;
  for (const [k, v] of Object.entries(obj)) {
    const key = String(k).trim().toLowerCase();
    if (!key) continue;
    const coerced = coerce(v);
    if (coerced !== undefined) out[key] = coerced;
  }
  return out;
}

export function summarizeCodexPool(rows, opts = {}) {
  const nowMs = Number.isFinite(opts.nowMs) ? opts.nowMs : Date.now();
  const nowSec = Math.floor(nowMs / 1000);
  const source = typeof opts.source === "string" && opts.source ? opts.source : "http";
  const accountCaps = normalizeMap(opts.accountCaps, (v) => {
    const n = Number(v);
    return Number.isFinite(n) && n > 0 && n <= 100 ? n : undefined;
  });
  const accountNames = normalizeMap(opts.accountNames, (v) =>
    typeof v === "string" && v.trim() ? v.trim() : undefined
  );
  const noCreditsSet = new Set(
    Array.from(opts.codexNoCredits ?? [], (x) => String(x ?? "").trim().toLowerCase()).filter(Boolean)
  );

  const offSeats = opts.offSeats instanceof Set ? opts.offSeats : new Set();

  const list = Array.isArray(rows) ? rows : [];
  const codexRows = list.filter(
    (r) => r?.provider === "codex" && !offSeats.has(codexSeatKey(r.provider, r?.user))
  );
  if (codexRows.length === 0) throw new Failure("no-seats");

  const freeRows = list.filter(
    (r) =>
      (r?.provider === "codex-free" || r?.provider === "plugin:codex-free") &&
      !offSeats.has(codexSeatKey(r.provider, r?.user))
  );

  const codexAccounts = codexRows.map((row) => {
    const user = String(row?.user ?? "");
    const userKey = user.trim().toLowerCase();
    const rowAlias = typeof row?.alias === "string" && row.alias.trim() ? row.alias.trim() : null;
    const alias = rowAlias ?? accountNames[userKey] ?? null;
    const label = shortLabel(user, alias);
    const plan = typeof row?.plan === "string" ? row.plan : null;
    const error = row?.error ? String(row.error) : null;
    const held = Boolean(row?.held);
    const balance = row?.balance ?? null;
    const wins = Array.isArray(row?.windows) ? row.windows : [];
    const w5 = parseWindow(wins, "5 hours", nowMs);
    const w7 = parseWindow(wins, "7 days", nowMs);

    const cap = accountCaps[userKey] ?? accountCaps["*"] ?? 100;
    const hasValidWindow = w5.used !== null || w7.used !== null;
    const windowAvail =
      !error &&
      !held &&
      hasValidWindow &&
      (w5.used === null || w5.used < cap) &&
      (w7.used === null || w7.used < cap);
    const balNum = parseBalanceNumber(balance);
    const creditsAvail =
      !error &&
      !held &&
      !windowAvail &&
      cap >= 100 &&
      balNum !== null &&
      balNum > 0 &&
      !noCreditsSet.has(userKey);
    const usable = windowAvail || creditsAvail;
    const usingCredits = !windowAvail && creditsAvail;

    const lastServedMs = parseTimestampMs(row?.lastServedAt ?? row?.last_served_at);
    const lastServedAt = lastServedMs !== null ? Math.floor(lastServedMs / 1000) : null;

    return {
      user,
      alias,
      short_label: label,
      plan,
      usable,
      windowAvail,
      using_credits: usingCredits,
      held,
      error,
      balance,
      lastServedMs,
      last_served_at: lastServedAt,
      used_5h_pct: w5.used,
      reset_5h_at: w5.resetAt,
      used_7d_pct: w7.used,
      reset_7d_at: w7.resetAt,
    };
  });

  let latestServed = null;
  for (const acct of codexAccounts) {
    if (acct.lastServedMs === null) continue;
    if (!latestServed || acct.lastServedMs > latestServed.lastServedMs) {
      latestServed = acct;
    }
  }

  let active = null;
  if (latestServed && latestServed.usable) {
    active = latestServed;
  } else {
    active = codexAccounts.find((a) => a.usable) ?? latestServed ?? codexAccounts[0];
  }

  let availSeats = 0;
  let windowAvailSeats = 0;
  let errorSeats = 0;
  for (const acct of codexAccounts) {
    if (acct.usable) availSeats++;
    if (acct.windowAvail) windowAvailSeats++;
    if (acct.error) errorSeats++;
  }

  let freeAvailSeats = 0;
  let freeErrorSeats = 0;
  let freeUsedSum = 0;
  let freeUsedCount = 0;
  let freeNextResetAt = null;
  for (const row of freeRows) {
    const error = row?.error ? String(row.error) : null;
    const held = Boolean(row?.held);
    if (error) freeErrorSeats++;
    const wins = Array.isArray(row?.windows) ? row.windows : [];
    const w30 = parseWindow(wins, "30 days", nowMs);
    if (w30.resetAt !== null && w30.resetAt > nowSec) {
      if (freeNextResetAt === null || w30.resetAt < freeNextResetAt) {
        freeNextResetAt = w30.resetAt;
      }
    }
    if (w30.used !== null) {
      freeUsedSum += w30.used;
      freeUsedCount++;
    }
    if (!error && !held && w30.used !== null && w30.used < 100) {
      freeAvailSeats++;
    }
  }

  return {
    source,
    active: {
      user: active.user,
      alias: active.alias,
      short_label: active.short_label,
      plan: active.plan,
      used_5h_pct: active.used_5h_pct,
      reset_5h_at: active.reset_5h_at,
      used_7d_pct: active.used_7d_pct,
      reset_7d_at: active.reset_7d_at,
      using_credits: active.using_credits,
      balance: active.balance,
      last_served_at: active.last_served_at,
    },
    avail_seats: availSeats,
    window_avail_seats: windowAvailSeats,
    total_seats: codexAccounts.length,
    error_seats: errorSeats,
    accounts: codexAccounts.map((a, idx) => ({
      order: idx + 1,
      user: a.user,
      alias: a.alias,
      short_label: a.short_label,
      plan: a.plan,
      is_active: a === active,
      usable: a.usable,
      using_credits: a.using_credits,
      held: a.held,
      error: a.error,
      balance: a.balance,
      last_served_at: a.last_served_at,
      used_5h_pct: a.used_5h_pct,
      reset_5h_at: a.reset_5h_at,
      used_7d_pct: a.used_7d_pct,
      reset_7d_at: a.reset_7d_at,
    })),
    free_pool: {
      avail_seats: freeAvailSeats,
      total_seats: freeRows.length,
      error_seats: freeErrorSeats,
      used_30d_pct: freeUsedCount > 0 ? Math.round(freeUsedSum / freeUsedCount) : null,
      next_reset_at: freeNextResetAt,
    },
  };
}

function readJsonSafe(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

function readCodexConfigExtras(configDir) {
  const providersDoc = readJsonSafe(join(configDir, "providers.json"));
  const providersList = Array.isArray(providersDoc?.providers) ? providersDoc.providers : [];
  const codexProvider = providersList.find((p) => p?.id === "codex");
  const accountCaps =
    codexProvider?.accountCaps && typeof codexProvider.accountCaps === "object"
      ? codexProvider.accountCaps
      : {};
  const accountNames =
    codexProvider?.accountNames && typeof codexProvider.accountNames === "object"
      ? codexProvider.accountNames
      : {};

  const settingsDoc = readJsonSafe(join(configDir, "settings.json"));
  const codexNoCredits = Array.isArray(settingsDoc?.codexNoCredits)
    ? settingsDoc.codexNoCredits
    : [];

  const offSeats = parseOffCodexSeats(readJsonSafe(join(configDir, "logins.json")));

  return { accountCaps, accountNames, codexNoCredits, offSeats };
}

function lookupQuotaEntry(quotasDoc, prefix, user) {
  const raw = String(user ?? "");
  const lower = raw.toLowerCase();
  return quotasDoc[`${prefix}/${lower}`] ?? quotasDoc[`${prefix}/${raw}`];
}

function loginOrderRank(order) {
  return typeof order === "number" && Number.isFinite(order) && order > 0
    ? order
    : Number.MAX_SAFE_INTEGER;
}

function readOfflineMirror(configDir, nowMs = Date.now()) {
  const rawLogins = readJsonSafe(join(configDir, "logins.json"));
  const loginList = Array.isArray(rawLogins)
    ? rawLogins
    : Array.isArray(rawLogins?.logins)
      ? rawLogins.logins
      : null;
  if (!loginList) return null;

  // Pick only routing metadata — never touch login tokens.
  const enabledLogins = loginList
    .map((entry, idx) => ({
      agent: entry?.agent,
      user: entry?.user,
      routable: isLoginRoutable(entry),
      order: entry?.order,
      idx,
    }))
    .filter(
      (l) =>
        l.routable &&
        typeof l.user === "string" &&
        l.user &&
        (l.agent === "codex" || l.agent === "plugin:codex-free")
    )
    .sort((a, b) => (loginOrderRank(a.order) - loginOrderRank(b.order)) || (a.idx - b.idx));

  const codexLogins = enabledLogins.filter((l) => l.agent === "codex");
  if (codexLogins.length === 0) throw new Failure("no-seats");

  const quotasDoc = readJsonSafe(join(configDir, "quotas.json"));
  if (!quotasDoc || typeof quotasDoc !== "object") throw new Failure("stale-mirror");

  let latestCodexReadMs = null;
  for (const login of codexLogins) {
    const entry = lookupQuotaEntry(quotasDoc, "codex", login.user);
    const readMs = parseTimestampMs(entry?.quota?.readAt ?? entry?.at);
    if (readMs !== null && (latestCodexReadMs === null || readMs > latestCodexReadMs)) {
      latestCodexReadMs = readMs;
    }
  }
  if (latestCodexReadMs === null || nowMs - latestCodexReadMs > MIRROR_MAX_AGE_MS) {
    throw new Failure("stale-mirror");
  }

  const servedDoc = readJsonSafe(join(configDir, "served.json")) ?? {};
  const rows = [];
  for (const login of enabledLogins) {
    const entry =
      login.agent === "codex"
        ? lookupQuotaEntry(quotasDoc, "codex", login.user)
        : lookupQuotaEntry(quotasDoc, "plugin:codex-free", login.user) ??
          lookupQuotaEntry(quotasDoc, "codex-free", login.user);
    const quota = entry?.quota;
    const provider = login.agent === "codex" ? "codex" : quota?.provider ?? "codex-free";
    const lastServedAt =
      login.agent === "codex"
        ? servedDoc[`codex@${login.user.toLowerCase()}`] ?? quota?.lastServedAt ?? null
        : null;
    if (quota && typeof quota === "object") {
      rows.push({ ...quota, provider, user: quota.user ?? login.user, lastServedAt });
    } else {
      rows.push({ provider, user: login.user, windows: [], lastServedAt });
    }
  }
  return rows;
}

export async function collectCodexPool(opts = {}) {
  const endpoint = opts.endpoint ?? ENDPOINT;
  const configDir = opts.configDir ?? CONFIG_DIR;
  const nowMs = Number.isFinite(opts.nowMs) ? opts.nowMs : Date.now();
  const extras = readCodexConfigExtras(configDir);

  let httpFailure = null;
  try {
    const res = await fetch(endpoint, {
      headers: { Host: "127.0.0.1:18417" },
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) {
      httpFailure = new Failure(`http-${res.status}`);
    } else {
      const body = await res.json().catch(() => null);
      if (Array.isArray(body?.data)) {
        return summarizeCodexPool(body.data, { ...extras, nowMs, source: "http" });
      }
      httpFailure = new Failure("invalid-response");
    }
  } catch (err) {
    httpFailure = err instanceof Failure ? err : new Failure("network-error");
  }

  const mirrorRows = readOfflineMirror(configDir, nowMs);
  if (!mirrorRows) throw httpFailure;
  return summarizeCodexPool(mirrorRows, { ...extras, nowMs, source: "mirror" });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const cacheJsonPath = join(CACHE_DIR, "vendor-codex-pool.json");
  const cacheStatusPath = join(CACHE_DIR, "vendor-codex-pool.status");
  try {
    const data = await collectCodexPool();
    writeAtomic("vendor-codex-pool.json", {
      fetched_at: Math.floor(Date.now() / 1000),
      data,
    });
    rmSync(cacheStatusPath, { force: true });
  } catch (err) {
    const reason = err instanceof Failure ? err.message : "unexpected";
    // Dormant when Magpie/Codex is unconfigured: stay out of wrapper.sh's vendor-codex-local fallback path.
    if (reason === "no-seats" || (!existsSync(CONFIG_DIR) && !existsSync(cacheJsonPath))) {
      rmSync(cacheJsonPath, { force: true });
      rmSync(cacheStatusPath, { force: true });
    } else {
      writeAtomic("vendor-codex-pool.status", {
        failed_at: Math.floor(Date.now() / 1000),
        reason,
      });
    }
  }
}
