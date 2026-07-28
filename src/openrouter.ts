/**
 * OpenRouter — provider constants and the curated summary-model shortlist.
 *
 * OpenRouter is reached through the same OpenAI-compatible client as Gemini and
 * DeepSeek: only the base URL and the API key differ. What is different is how
 * its models are admitted. The weekly models.dev auto-admit (`filterCatalog`)
 * does not see OpenRouter at all — its 300+ ids would drown every picker, and a
 * personal tool uses a handful. These entries are hand-picked here, merged into
 * the effective catalog at read time, and therefore survive every refresh: a
 * refresh only rewrites the auto-admitted cache, which has never contained them.
 *
 * The ids below were verified against a live `GET https://openrouter.ai/api/v1/models`
 * on 2026-07-27 (that endpoint needs no auth). They are the canonical undated
 * slugs — never a dated variant, which would rot on the vendor's schedule.
 *
 * No pricing is stored. OpenRouter routes a single slug across providers whose
 * rates differ and change without our knowing, so a number here would be a
 * confident lie; cost lines print {@link OPENROUTER_COST_NOTE} instead.
 *
 * Mirrored in Swift by `ModelRegistry.openRouterModels`
 * (macos/Nota/App/ModelRegistry.swift). This file is the source of truth —
 * change it first, then the mirror.
 */

import type { CatalogModelEntry } from "./catalog.js";

/** OpenRouter's OpenAI-compatible endpoint. */
export const OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1";

/** Env var / ~/.nota/config key holding the OpenRouter API key. */
export const OPENROUTER_API_KEY_ENV = "OPENROUTER_API_KEY";

/** Printed wherever a dollar figure would go for an OpenRouter model. */
export const OPENROUTER_COST_NOTE = "refer to OpenRouter";

function openRouterEntry(
  /** The slug as OpenRouter serves it, e.g. `anthropic/claude-sonnet-5`. */
  slug: string,
  label: string,
  contextTokens: number,
): CatalogModelEntry {
  return {
    id: `openrouter/${slug}`,
    provider: "openrouter",
    label,
    task: "summary",
    // No `cost`: see the module note.
    costNote: OPENROUTER_COST_NOTE,
    limit: { context: contextTokens },
    execution: "http",
    origin: "curated",
  };
}

/**
 * The shortlist. Six frontier chat models, one per lab, all text-output and
 * long-context enough to summarize a meeting in one call.
 */
export const OPENROUTER_MODELS: readonly CatalogModelEntry[] = [
  openRouterEntry("anthropic/claude-sonnet-5", "Claude Sonnet 5 (OpenRouter)", 1_000_000),
  openRouterEntry("anthropic/claude-haiku-4.5", "Claude Haiku 4.5 (OpenRouter)", 200_000),
  openRouterEntry("moonshotai/kimi-k2.6", "Kimi K2.6 (OpenRouter)", 262_144),
  openRouterEntry("qwen/qwen3.7-max", "Qwen3.7 Max (OpenRouter)", 1_000_000),
  openRouterEntry("z-ai/glm-5.2", "GLM 5.2 (OpenRouter)", 1_048_576),
  openRouterEntry("meta-llama/llama-4-maverick", "Llama 4 Maverick (OpenRouter)", 1_048_576),
];
