#!/usr/bin/env node
// Grok Bot weekly usage -> ~/.claude/cache/vendor-grok-bot-local.{json,status}
// Grok Bot is a separate pool from Grok Build's _x.ai/billing; the app reads it from
// Cursor's DashboardService with the Cursor account it logged in with.
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const HOME = homedir();
const SECRETS = join(HOME, "Library/Application Support/Grok Bot/sand-secrets.json");
const CACHE_DIR = join(HOME, ".claude/cache");
const SAMPLES = process.env.GROK_QUOTA_SAMPLES ?? join(HOME, ".cli-proxy-api/grok-quota-samples.jsonl");
const ENDPOINT = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus";

class Failure extends Error {}

function writeAtomic(name, payload) {
  mkdirSync(CACHE_DIR, { recursive: true });
  const path = join(CACHE_DIR, name);
  writeFileSync(`${path}.tmp`, JSON.stringify(payload), { mode: 0o600 });
  renameSync(`${path}.tmp`, path);
}

// Electron safeStorage on macOS: "v10" + AES-128-CBC, key = PBKDF2(keychain password).
function decryptSafeStorage(b64, password) {
  const raw = Buffer.from(b64, "base64");
  if (raw.subarray(0, 3).toString("latin1") !== "v10") throw new Failure("decrypt");
  const key = crypto.pbkdf2Sync(password, "saltysalt", 1003, 16, "sha1");
  const decipher = crypto.createDecipheriv("aes-128-cbc", key, Buffer.alloc(16, " "));
  return Buffer.concat([decipher.update(raw.subarray(3)), decipher.final()]).toString("utf8");
}

// Read-only: refreshing here would rotate the refresh token out from under the app.
function readAccessToken() {
  let accounts;
  try {
    accounts = JSON.parse(JSON.parse(readFileSync(SECRETS, "utf8"))["cursor-accounts"]);
  } catch {
    throw new Failure("no-session");
  }
  const encrypted = accounts?.accounts?.[accounts?.active]?.["cursor-access-token"];
  if (typeof encrypted !== "string") throw new Failure("no-session");
  let password;
  try {
    password = execFileSync("/usr/bin/security", ["find-generic-password", "-w", "-s", "Grok Bot Safe Storage"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trimEnd();
  } catch {
    throw new Failure("keychain");
  }
  try {
    return decryptSafeStorage(encrypted, password);
  } catch {
    throw new Failure("decrypt");
  }
}

async function fetchUsage(token) {
  let res;
  try {
    res = await fetch(ENDPOINT, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json", "connect-protocol-version": "1" },
      body: "{}",
      // the daemon runs widgets serially, so a hung request would freeze every other widget
      signal: AbortSignal.timeout(5000)
    });
  } catch {
    throw new Failure("network-error");
  }
  if (!res.ok) throw new Failure(`http-${res.status}`);
  const body = await res.json().catch(() => null);
  // Heavy expired -> Free plan with zero included quota; omit the cache so the pill hides instead of faking 0%.
  if (body?.includedLimitZero === true) return null;
  const used = body?.usagePercent ?? 0;
  const resetAt = Math.floor(Date.parse(body?.nextResetTimestampUtc ?? "") / 1000);
  if (!Number.isFinite(used) || used < 0 || !Number.isFinite(resetAt) || resetAt <= 0) {
    throw new Failure("invalid-response");
  }
  return { used_percent: used, reset_at: resetAt };
}

// Dormant when the Grok Build sampler is parked (samples file archived/absent): skip network polling.
if (!existsSync(SAMPLES)) {
  rmSync(join(CACHE_DIR, "vendor-grok-bot-local.json"), { force: true });
  rmSync(join(CACHE_DIR, "vendor-grok-bot-local.status"), { force: true });
  process.exit(0);
}

try {
  const data = await fetchUsage(readAccessToken());
  if (data === null) {
    rmSync(join(CACHE_DIR, "vendor-grok-bot-local.json"), { force: true });
    rmSync(join(CACHE_DIR, "vendor-grok-bot-local.status"), { force: true });
  } else {
    writeAtomic("vendor-grok-bot-local.json", { fetched_at: Math.floor(Date.now() / 1000), data });
  }
} catch (err) {
  if (existsSync(join(CACHE_DIR, "vendor-grok-bot-local.json"))) {
    const reason = err instanceof Failure ? err.message : "unexpected";
    writeAtomic("vendor-grok-bot-local.status", { failed_at: Math.floor(Date.now() / 1000), reason });
  }
}
