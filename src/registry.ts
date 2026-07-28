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
  /** How this model runs (ADR 0002). Everything today is `http`. */
  execution: ExecutionKind;
  /** Name of the env var holding the API key this model needs. */
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

const API_KEY_ENV: Record<ModelProvider, string> = {
  assemblyai: "ASSEMBLYAI_API_KEY",
  openai: "OPENAI_API_KEY",
  gemini: "GEMINI_API_KEY",
  deepseek: "DEEPSEEK_API_KEY",
  openrouter: OPENROUTER_API_KEY_ENV,
};

/** OpenAI-compatible base URL per provider, where one is needed. */
const BASE_URL: Partial<Record<ModelProvider, string>> = {
  gemini: GEMINI_OPENAI_BASE_URL,
  deepseek: DEEPSEEK_BASE_URL,
  openrouter: OPENROUTER_BASE_URL,
};

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
