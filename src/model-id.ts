/**
 * Model-id grammar and execution kinds — the two pieces of vocabulary that both
 * the registry and the catalog need, in a module that imports neither.
 *
 * ADR 0002: a model id is one string that fully names a summarizer. It is
 * either **flat** (`gpt-5-mini`) or **namespaced**
 * (`openrouter/anthropic/claude-sonnet-5`); for a namespaced id the first path
 * segment names the provider, and for a flat one the provider comes from the
 * registry's lookup table exactly as it always did. Provider is still never
 * stored and never chosen directly.
 *
 * This module is deliberately dependency-free so `catalog.ts` (which
 * `registry.ts` imports) can use it without a cycle.
 */

/** Every provider Nota can reach. Namespaces are drawn from this set. */
export const MODEL_PROVIDERS = [
  "assemblyai",
  "openai",
  "gemini",
  "deepseek",
  "openrouter",
] as const;

export type ModelProvider = (typeof MODEL_PROVIDERS)[number];

const PROVIDER_SET: ReadonlySet<string> = new Set(MODEL_PROVIDERS);

export function isModelProvider(value: unknown): value is ModelProvider {
  return typeof value === "string" && PROVIDER_SET.has(value);
}

/**
 * How a model runs. `http` is an OpenAI-compatible endpoint reached with an API
 * key; `cli` is a local subprocess (ADR 0003 — no entry uses it yet). Surfaces
 * that cannot host a subprocess filter on this **structurally**; matching on id
 * prefixes is explicitly not the mechanism (ADR 0002).
 */
export const EXECUTION_KINDS = ["http", "cli"] as const;

export type ExecutionKind = (typeof EXECUTION_KINDS)[number];

/** What an entry that names no execution kind means. */
export const DEFAULT_EXECUTION: ExecutionKind = "http";

const EXECUTION_SET: ReadonlySet<string> = new Set(EXECUTION_KINDS);

export function isExecutionKind(value: unknown): value is ExecutionKind {
  return typeof value === "string" && EXECUTION_SET.has(value);
}

/**
 * Resolve an entry's execution kind. `undefined` means "not stated" and yields
 * the default; anything else unrecognized yields `undefined`, which callers
 * turn into "drop this entry" — a build that does not understand a kind must
 * not guess that it is safe to run.
 */
export function resolveExecutionKind(
  value: unknown,
): ExecutionKind | undefined {
  if (value === undefined || value === null) return DEFAULT_EXECUTION;
  return isExecutionKind(value) ? value : undefined;
}

/** The first path segment of a namespaced id, or `undefined` for a flat id. */
export function namespaceOf(id: string): string | undefined {
  const slash = id.indexOf("/");
  if (slash <= 0) return undefined;
  return id.slice(0, slash);
}

/**
 * Derive the provider for a model id.
 *
 * - Namespaced: the namespace decides, and an unregistered namespace is a
 *   rejection (`undefined`) rather than a fallback to `declared` — an id that
 *   names a provider Nota does not have is not a model Nota can run.
 * - Flat: the caller's `declared` provider (the registry row or the catalog
 *   entry's `provider` field) decides, unchanged from before namespacing.
 */
export function deriveProvider(
  id: string,
  declared?: string,
): ModelProvider | undefined {
  const ns = namespaceOf(id);
  if (ns !== undefined) {
    return isModelProvider(ns) ? ns : undefined;
  }
  return isModelProvider(declared) ? declared : undefined;
}

/**
 * The model string the provider's own API expects.
 *
 * Nota's id namespaces the provider; OpenRouter's API does not want its own
 * name back (`anthropic/claude-sonnet-5`, not
 * `openrouter/anthropic/claude-sonnet-5`). Only a leading segment that is a
 * known provider is stripped, and only once — the rest of the path is the
 * provider's own id and is passed through verbatim.
 */
export function wireModelId(id: string): string {
  const ns = namespaceOf(id);
  if (ns === undefined || !isModelProvider(ns)) return id;
  return id.slice(ns.length + 1);
}
