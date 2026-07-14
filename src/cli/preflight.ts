/**
 * `nota preflight [--json] [--refresh]` — run the end-to-end readiness gate and
 * report it. Human output is a traffic-light list on stdout; `--json` emits the
 * machine contract the macOS home consumes. A fresh green result is cached for a
 * few minutes (see preflight-cache); `--refresh` bypasses the cache.
 */

import type { AppConfig } from "../config.js";
import { runPreflight, type PreflightResult, type CheckStatus } from "../pipeline/preflight.js";
import { readCache, writeCache } from "../pipeline/preflight-cache.js";

export interface PreflightCliOptions {
  json?: boolean;
  refresh?: boolean;
}

/**
 * Resolve a preflight result, using the short-lived cache unless `refresh` is
 * set. The freshly-run result is written back (green caches, red/yellow clear).
 */
export async function resolvePreflight(
  config: AppConfig,
  opts: { refresh?: boolean } = {},
): Promise<PreflightResult> {
  if (!opts.refresh) {
    const cached = await readCache(config);
    if (cached) return cached;
  }
  const result = await runPreflight(config);
  await writeCache(config, result);
  return result;
}

const GLYPH: Record<CheckStatus, string> = {
  ok: "✔", // ✔
  fail: "✖", // ✖
  unverified: "⚠", // ⚠
  optional: "○", // ○
};

const OVERALL_LINE: Record<PreflightResult["overall"], string> = {
  ready: "Ready to record — all checks passed.",
  blocked: "Not ready — fix the failing check(s) before recording.",
  unverified: "Couldn't verify everything — you can record, but a run may fail.",
};

function renderHuman(result: PreflightResult): string {
  const lines = result.checks.map(
    (c) => `${GLYPH[c.status]}  ${c.label}\n    ${c.detail}`,
  );
  return `${lines.join("\n")}\n\n${OVERALL_LINE[result.overall]}`;
}

/**
 * Print the preflight result and return the process exit code (0 ready or
 * unverified, 1 blocked) so `nota preflight` is scriptable. `unverified` is a
 * soft warning, not a hard failure, so it does not exit non-zero.
 */
export async function preflightCommand(
  config: AppConfig,
  opts: PreflightCliOptions = {},
): Promise<number> {
  const result = await resolvePreflight(config, { refresh: opts.refresh });
  if (opts.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    process.stdout.write(`${renderHuman(result)}\n`);
  }
  return result.overall === "blocked" ? 1 : 0;
}
