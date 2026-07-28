/**
 * Model registry — the single source of truth mapping a model id to its task,
 * provider, the API key env var it requires, and (where applicable) the
 * OpenAI-compatible base URL to reach it.
 *
 * Rules enforced here:
 * - Only curated model ids are valid. There is no free-text model id and no
 *   user-chosen provider — the provider is ALWAYS derived from the model id
 *   (ADR 0001, 0002). A namespaced id
 *   (`openrouter/anthropic/claude-sonnet-5`) names its provider in the first
 *   path segment; a flat id (`gpt-5-mini`) uses the lookup below.
 * - Transcription model ids are statically curated in `MODELS`.
 * - Summary model ids are sourced dynamically from the catalog
 *   (`~/.nota/models-catalog.json` or baked snapshot). They are auto-admitted
 *   weekly via `nota models refresh`, except the OpenRouter shortlist, which is
 *   hand-curated in `src/openrouter.ts` and merged in at read time.
 * - Gemini, DeepSeek and OpenRouter summarization all go through the same
 *   OpenAI-compatible client with a swapped base URL and their own API key.
 * - `claude-code/*` and `codex/*` go through no client at all: they are local
 *   subprocesses with `execution: "cli"`, no API key and no base URL
 *   (`src/cli-engines.ts`, ADR 0003).
 */

import { effectiveCatalog, findCatalogEntry } from "./catalog.js";
import type { CatalogModelEntry } from "./catalog.js";
import {
  DEFAULT_EXECUTION,
  deriveProvider,
  resolveExecutionKind,
  wireModelId,
  type ExecutionKind,
  type ModelProvider,
} from "./model-id.js";
import {
  OPENROUTER_API_KEY_ENV,
  OPENROUTER_BASE_URL,
} from "./openrouter.js";

export type ModelTask = "transcription" | "summary";

export type { ExecutionKind, ModelProvider };
export { OPENROUTER_BASE_URL };

export interface ModelEntry {
  /** Canonical model id (what callers pass and what we persist). */
  id: string;
  /**
   * The model string the provider's own API expects — the canonical id with a
   * provider namespace stripped. Equal to `id` for every flat id.
   */
  wireId: string;
  task: ModelTask;
  provider: ModelProvider;
  /** How this model runs (ADR 0002): an HTTP endpoint or a local subprocess. */
  execution: ExecutionKind;
  /**
   * Name of the env var holding the API key this model needs — empty for a
   * `cli` engine, which needs none. Ask {@link requiresApiKey}, not this field.
   */
  apiKeyEnv: string;
  /** Human-facing label for pickers / diagnostics. */
  label: string;
  /** OpenAI-compatible base URL, where the provider needs one. */
  baseURL?: string;
}

/**
 * Google's Gemini exposes an OpenAI-compatible endpoint, so the same OpenAI
 * client summarizes with Gemini by swapping the base URL and using a
 * `gemini-*` model with GEMINI_API_KEY.
 * See https://ai.google.dev/gemini-api/docs/openai
 */
export const GEMINI_OPENAI_BASE_URL =
  "https://generativelanguage.googleapis.com/v1beta/openai/";

/**
 * DeepSeek's API is OpenAI-compatible at this base URL.
 * See https://api-docs.deepseek.com
 */
export const DEEPSEEK_BASE_URL = "https://api.deepseek.com";

/**
 * The env var each provider's key lives in. Empty for a CLI provider: a local
 * subprocess authenticates through its own login and is billed to a
 * subscription (ADR 0003). Callers must decide "does this need a key?" from the
 * **execution kind** — see {@link requiresApiKey} — never from an empty string
 * or from the id.
 */
const API_KEY_ENV: Record<ModelProvider, string> = {
  assemblyai: "ASSEMBLYAI_API_KEY",
  openai: "OPENAI_API_KEY",
  gemini: "GEMINI_API_KEY",
  deepseek: "DEEPSEEK_API_KEY",
  openrouter: OPENROUTER_API_KEY_ENV,
  "claude-code": "",
  codex: "",
};

/** OpenAI-compatible base URL per provider, where one is needed. */
const BASE_URL: Partial<Record<ModelProvider, string>> = {
  gemini: GEMINI_OPENAI_BASE_URL,
  deepseek: DEEPSEEK_BASE_URL,
  openrouter: OPENROUTER_BASE_URL,
};

function normalizeBaseURL(url: string): string {
  return url.replace(/\/+$/, "");
}

/** Inverse of {@link BASE_URL} — which provider owns an OpenAI-compatible endpoint. */
const PROVIDER_BY_BASE_URL: ReadonlyMap<string, ModelProvider> = new Map(
  Object.entries(BASE_URL).map(([provider, url]) => [
    normalizeBaseURL(url as string),
    provider as ModelProvider,
  ]),
);

/**
 * The provider an OpenAI-compatible base URL belongs to, or `undefined` for
 * OpenAI's own default endpoint (which is expressed as *no* base URL) and for
 * anything unrecognized.
 *
 * This exists because a request carries the **wire** id, and a wire id has had
 * the one segment that names its provider stripped off:
 * `anthropic/claude-sonnet-5` is not a model the registry can look up. The
 * endpoint the request is addressed to still names the provider, and it is the
 * party that decides which request parameters are accepted — so where a request
 * shape must be chosen per provider, the URL is the authority the id can no
 * longer be.
 */
export function providerForBaseURL(
  baseURL: string | undefined,
): ModelProvider | undefined {
  if (!baseURL) return undefined;
  return PROVIDER_BY_BASE_URL.get(normalizeBaseURL(baseURL));
}

/** Built-in defaults used when neither a CLI flag nor settings.json applies. */
export const DEFAULT_TRANSCRIPTION_MODEL = "universal";
export const DEFAULT_SUMMARY_MODEL = "gpt-5-mini";

function entry(
  id: string,
  task: ModelTask,
  provider: ModelProvider,
  label: string,
): ModelEntry {
  return {
    id,
    wireId: wireModelId(id),
    task,
    provider,
    execution: DEFAULT_EXECUTION,
    apiKeyEnv: API_KEY_ENV[provider],
    label,
    baseURL: BASE_URL[provider],
  };
}

// ── Static transcription entries ─────────────────────────────────────────────

export const MODELS: readonly ModelEntry[] = [
  entry("universal", "transcription", "assemblyai", "Universal (AssemblyAI)"),
  entry("whisper-1", "transcription", "openai", "Whisper (OpenAI)"),
  entry(
    "gpt-4o-transcribe",
    "transcription",
    "openai",
    "GPT-4o Transcribe (OpenAI)",
  ),
  entry(
    "gpt-4o-mini-transcribe",
    "transcription",
    "openai",
    "GPT-4o mini Transcribe (OpenAI)",
  ),
];

const BY_ID = new Map(MODELS.map((m) => [m.id, m]));

// ── Catalog bridging ─────────────────────────────────────────────────────────

/**
 * Bridge a catalog entry into a registry entry, or `undefined` when this build
 * cannot serve it: an id whose namespace names no provider we have, or an
 * execution kind we do not recognize. `effectiveCatalog` already drops both, so
 * this is a second, local guard for callers that hand us an entry directly.
 */
function catalogEntryToModel(cat: CatalogModelEntry): ModelEntry | undefined {
  const provider = deriveProvider(cat.id, cat.provider);
  if (provider === undefined) return undefined;
  const execution = resolveExecutionKind(cat.execution);
  if (execution === undefined) return undefined;
  return {
    id: cat.id,
    wireId: wireModelId(cat.id),
    task: "summary",
    provider,
    execution,
    apiKeyEnv: API_KEY_ENV[provider],
    label: cat.label,
    baseURL: BASE_URL[provider],
  };
}

/** Resolve summary model entries from the effective catalog. */
function summaryModelsFromCatalog(): ModelEntry[] {
  const { catalog } = effectiveCatalog();
  return catalog.models
    .map(catalogEntryToModel)
    .filter((m): m is ModelEntry => m !== undefined);
}

/**
 * Resolve summary model entries from the effective catalog, returned as catalog
 * entries for cost/label/limit lookups. Used by pricing to read rates.
 */
export function summaryCatalogEntries(): CatalogModelEntry[] {
  const { catalog } = effectiveCatalog();
  return [...catalog.models];
}

/**
 * Look up a model by id, or `undefined` if it is not in the registry.
 * Checks the static transcription list first, then the catalog for summary
 * models.
 */
export function getModel(id: string): ModelEntry | undefined {
  const staticEntry = BY_ID.get(id);
  if (staticEntry) return staticEntry;

  const { catalog } = effectiveCatalog();
  const catEntry = findCatalogEntry(catalog, id);
  if (catEntry) return catalogEntryToModel(catEntry);

  return undefined;
}

/**
 * Models a surface may run in-process over HTTP. The dictation polish picker
 * filters on this — structurally, on the execution kind, never by matching id
 * prefixes (ADR 0002), so a catalog refresh can never leak a subprocess engine
 * into a per-sentence streaming path.
 */
export function httpModelsForTask(task: ModelTask): ModelEntry[] {
  return modelsForTask(task).filter((m) => m.execution === "http");
}

/**
 * Whether resolving this model requires an API key. The question is answered by
 * the execution kind and nothing else: a `cli` engine's precondition is a binary
 * on PATH and a login, so demanding a key would refuse a run that would have
 * worked (ADR 0003). Reading `apiKeyEnv` for emptiness would be the same test
 * spelled less honestly.
 */
export function requiresApiKey(entry: ModelEntry): boolean {
  return entry.execution === "http";
}

/** All models for a given task, in registry order. */
export function modelsForTask(task: ModelTask): ModelEntry[] {
  if (task === "transcription") {
    return MODELS.filter((m) => m.task === task);
  }
  return summaryModelsFromCatalog();
}

function validIdList(task: ModelTask): string {
  return modelsForTask(task)
    .map((m) => m.id)
    .join(", ");
}

/**
 * Resolve a model id for a specific task, throwing a helpful error (listing the
 * valid ids for that task) when the id is unknown or belongs to another task.
 */
export function requireModel(id: string, task: ModelTask): ModelEntry {
  const model = getModel(id);
  if (!model) {
    throw new Error(
      `Unknown ${task} model: ${id}. Valid ${task} models: ${validIdList(task)}`,
    );
  }
  if (model.task !== task) {
    throw new Error(
      `Model ${id} is a ${model.task} model, not a ${task} model. ` +
        `Valid ${task} models: ${validIdList(task)}`,
    );
  }
  return model;
}

/** True when a model name targets Gemini rather than OpenAI. */
export function isGeminiModel(id: string): boolean {
  return getModel(id)?.provider === "gemini";
}

/**
 * Providers whose OpenAI-compatible endpoint caps output with `max_tokens`
 * rather than OpenAI's `max_completion_tokens`.
 *
 * - **gemini** — the shim maps `max_tokens` onto Google's `maxOutputTokens` and
 *   understands nothing else.
 * - **openrouter** — `max_tokens` is the normalized parameter every route
 *   accepts. OpenRouter *drops* a parameter the chosen route does not support
 *   instead of erroring, so sending `max_completion_tokens` to a route that
 *   wants `max_tokens` is worse than a failure: the cap is silently not applied
 *   and only the bill says so.
 *
 * OpenAI itself is the other way round — `max_tokens` is rejected outright by
 * the gpt-5 family — and DeepSeek accepts OpenAI's spelling, so both keep it.
 */
const MAX_TOKENS_PROVIDERS: ReadonlySet<ModelProvider> = new Set<ModelProvider>([
  "gemini",
  "openrouter",
]);

/**
 * True when the summary request for this model+endpoint must cap output with
 * `max_tokens`. The base URL is consulted first: it is where the request is
 * actually going, and for a namespaced model it is the only thing left that
 * names the provider (see {@link providerForBaseURL}).
 */
export function usesMaxTokensParam(
  wireId: string,
  baseURL?: string,
): boolean {
  const provider = providerForBaseURL(baseURL) ?? getModel(wireId)?.provider;
  return provider !== undefined && MAX_TOKENS_PROVIDERS.has(provider);
}
