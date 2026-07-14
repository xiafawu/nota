/**
 * Preflight result cache. Only a fully-`ready` result is ever cached, and only
 * briefly: reopening the app shouldn't re-run the canary calls every time, but a
 * `blocked`/`unverified` result must always be re-checked (the user is likely
 * fixing it, and a stale red would be worse than an extra call). The cache is
 * fingerprinted by the resolved models so changing a model in Settings
 * invalidates it immediately.
 */

import { homedir } from "node:os";
import path from "node:path";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import type { AppConfig } from "../config.js";
import type { PreflightResult } from "./preflight.js";

/** How long a green result stays fresh. */
export const CACHE_TTL_MS = 5 * 60 * 1000;

export function cachePath(): string {
  return (
    process.env.NOTA_PREFLIGHT_CACHE ??
    path.join(homedir(), ".nota", "preflight-cache.json")
  );
}

/** Fingerprint the inputs that change what preflight would find. */
export function fingerprint(config: AppConfig): string {
  return [
    config.provider,
    config.transcriptionModel,
    config.summaryModel,
    config.identify ? "id" : "no-id",
    config.diarize ? "dia" : "no-dia",
  ].join("|");
}

interface CacheFile {
  fingerprint: string;
  result: PreflightResult;
}

/**
 * Return a cached `ready` result if it matches this config and is younger than
 * the TTL; otherwise null. Any read/parse error is swallowed (cache is advisory).
 */
export async function readCache(
  config: AppConfig,
  now: number = Date.now(),
): Promise<PreflightResult | null> {
  try {
    const raw = await readFile(cachePath(), "utf-8");
    const cached = JSON.parse(raw) as CacheFile;
    if (cached.fingerprint !== fingerprint(config)) return null;
    if (cached.result.overall !== "ready") return null;
    const age = now - Date.parse(cached.result.checkedAt);
    if (!Number.isFinite(age) || age < 0 || age > CACHE_TTL_MS) return null;
    return cached.result;
  } catch {
    return null;
  }
}

/** Persist a `ready` result; other outcomes clear any prior cache entry. */
export async function writeCache(
  config: AppConfig,
  result: PreflightResult,
): Promise<void> {
  try {
    const file = cachePath();
    await mkdir(path.dirname(file), { recursive: true });
    if (result.overall !== "ready") {
      await writeFile(file, "{}", "utf-8");
      return;
    }
    const payload: CacheFile = { fingerprint: fingerprint(config), result };
    await writeFile(file, JSON.stringify(payload), "utf-8");
  } catch {
    // Cache is advisory — a write failure must never break preflight.
  }
}
