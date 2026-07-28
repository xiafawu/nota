/**
 * CLI engines — the two summarizers that are not HTTP APIs at all (ADR 0003).
 *
 * `claude-code/*` and `codex/*` name a **local subprocess**: Nota spawns the
 * `claude` or `codex` binary already installed on the machine, hands it the same
 * prompt the HTTP path builds, and reads plain text back. There is no API key
 * and no base URL — the CLI authenticates with its own login and the work is
 * billed through the owner's subscription, which is the entire point.
 *
 * Admission is by hand for the same reason OpenRouter's is (see
 * `src/openrouter.ts`): these are aliases and slugs a vendor rotates, not a feed
 * we can filter. Entries are merged into the effective catalog at read time, so
 * `nota models refresh` — which only ever rewrites the auto-admitted cache —
 * cannot remove them.
 *
 * They are **never** mirrored into the macOS app. Dictation polish is
 * latency-bound (per sentence in streaming mode) and every app-side surface
 * filters on `execution === "http"`, so nothing here can leak into it. That
 * exclusion is structural, not a convention about id prefixes (ADR 0002).
 *
 * Verified 2026-07-28 against the installed binaries — `claude --version`
 * 2.1.220 and `codex-cli 0.144.0`:
 *   - `claude --model` documents `'fable'`, `'opus'`, `'sonnet'` as aliases for
 *     "the latest model" of each tier, and accepts full names too. The aliases
 *     are what we curate: an alias tracks the vendor's rotation, a dated name
 *     rots on their schedule.
 *   - `codex exec -m` takes a slug from the CLI's own model list
 *     (`~/.codex/models_cache.json`, `visibility: "list"`). The six listed there
 *     were `gpt-5.6-sol|terra|luna`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`.
 * Re-verify before editing either list; do not recall them.
 */

import type { CatalogModelEntry } from "./catalog.js";

/** Providers whose models run as a local subprocess rather than over HTTP. */
export const CLI_PROVIDERS = ["claude-code", "codex"] as const;

export type CliProvider = (typeof CLI_PROVIDERS)[number];

const CLI_PROVIDER_SET: ReadonlySet<string> = new Set(CLI_PROVIDERS);

export function isCliProvider(value: unknown): value is CliProvider {
  return typeof value === "string" && CLI_PROVIDER_SET.has(value);
}

/** The executable each provider names, as it must appear on PATH. */
export const CLI_BINARY: Record<CliProvider, string> = {
  "claude-code": "claude",
  codex: "codex",
};

/** Human name for the product, for error messages that tell you what to install. */
export const CLI_PRODUCT: Record<CliProvider, string> = {
  "claude-code": "Claude Code",
  codex: "Codex CLI",
};

/** What to run to authenticate, named in the error when a run is refused. */
export const CLI_LOGIN_HINT: Record<CliProvider, string> = {
  "claude-code": "run `claude` once and sign in",
  codex: "run `codex login`",
};

/**
 * Printed wherever a dollar figure would go for a CLI-engine run. Not "$0.00":
 * the work was paid for, just not per token and not on this ledger.
 */
export const CLI_COST_NOTE = "included w/ subscription";

function cliEntry(
  provider: CliProvider,
  /** Exactly what the CLI's `--model`/`-m` flag expects — this becomes the wire id. */
  wireModel: string,
  label: string,
  contextTokens: number,
): CatalogModelEntry {
  return {
    id: `${provider}/${wireModel}`,
    provider,
    label,
    task: "summary",
    // No `cost`: a subscription has no per-token rate to record. Absent is not
    // zero — displays print `costNote` instead of a figure.
    costNote: CLI_COST_NOTE,
    limit: { context: contextTokens },
    execution: "cli",
    origin: "cli",
  };
}

/**
 * Claude Code's three tier aliases. The context figure is a deliberate **floor**:
 * an alias resolves to whatever model the installed CLI considers latest for
 * that tier, so the only honest number is one no member falls below.
 */
const CLAUDE_CODE_CONTEXT_FLOOR = 200_000;

/** Every codex model the installed CLI lists reports the same context window. */
const CODEX_CONTEXT = 272_000;

/** The curated CLI-engine shortlist, in picker order. */
export const CLI_ENGINE_MODELS: readonly CatalogModelEntry[] = [
  cliEntry("claude-code", "sonnet", "Claude Sonnet (Claude Code)", CLAUDE_CODE_CONTEXT_FLOOR),
  cliEntry("claude-code", "opus", "Claude Opus (Claude Code)", CLAUDE_CODE_CONTEXT_FLOOR),
  cliEntry("claude-code", "haiku", "Claude Haiku (Claude Code)", CLAUDE_CODE_CONTEXT_FLOOR),
  cliEntry("codex", "gpt-5.6-sol", "GPT-5.6-Sol (Codex)", CODEX_CONTEXT),
  cliEntry("codex", "gpt-5.6-terra", "GPT-5.6-Terra (Codex)", CODEX_CONTEXT),
  cliEntry("codex", "gpt-5.6-luna", "GPT-5.6-Luna (Codex)", CODEX_CONTEXT),
  cliEntry("codex", "gpt-5.4-mini", "GPT-5.4-Mini (Codex)", CODEX_CONTEXT),
];
