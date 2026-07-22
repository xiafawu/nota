/**
 * Model registry — the single source of truth mapping a model id to its task,
 * provider, the API key env var it requires, and (where applicable) the
 * OpenAI-compatible base URL to reach it.
 *
 * Rules enforced here:
 * - Only curated model ids are valid. There is no free-text model id and no
 *   user-chosen provider — the provider is ALWAYS derived from the model id.
 * - Transcription model ids are statically curated in `MODELS`.
 * - Summary model ids are sourced dynamically from the catalog
 *   (`~/.nota/models-catalog.json` or baked snapshot). They are auto-admitted
 *   weekly via `nota models refresh`.
 * - Gemini summarization is reached through the OpenAI-compatible endpoint
 *   (`GEMINI_OPENAI_BASE_URL`), so it uses the same OpenAI client with a
 *   swapped base URL and `GEMINI_API_KEY`.
 */

import { effectiveCatalog, findCatalogEntry } from "./catalog.js";
import type { CatalogModelEntry } from "./catalog.js";

export type ModelTask = "transcription" | "summary";
export type ModelProvider = "assemblyai" | "openai" | "gemini" | "deepseek";

export interface ModelEntry {
  /** Canonical model id (what callers pass and what we persist). */
  id: string;
  task: ModelTask;
  provider: ModelProvider;
  /** Name of the env var holding the API key this model needs. */
  apiKeyEnv: string;
  /** Human-facing label for pickers / diagnostics. */
  label: string;
  /** OpenAI-compatible base URL, where the provider needs one (gemini). */
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
};

/** OpenAI-compatible base URL per provider, where one is needed. */
const BASE_URL: Partial<Record<ModelProvider, string>> = {
  gemini: GEMINI_OPENAI_BASE_URL,
  deepseek: DEEPSEEK_BASE_URL,
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
    task,
    provider,
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

function catalogEntryToModel(cat: CatalogModelEntry): ModelEntry {
  const p = cat.provider as ModelProvider;
  return {
    id: cat.id,
    task: "summary",
    provider: p,
    apiKeyEnv: API_KEY_ENV[p] ?? "OPENAI_API_KEY",
    label: cat.label,
    baseURL: BASE_URL[p],
  };
}

/** Resolve summary model entries from the effective catalog. */
function summaryModelsFromCatalog(): ModelEntry[] {
  const { catalog } = effectiveCatalog();
  return catalog.models.map(catalogEntryToModel);
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
