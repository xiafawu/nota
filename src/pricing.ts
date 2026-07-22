/**
 * Model pricing — transcription-only per-duration rates (USD).
 * Summary model cost is computed from the live catalog at snapshot time
 * (see `computeSummaryCost` in catalog.ts).
 *
 * All USD. Point-in-time snapshot, not a live source. Re-compute cost at write
 * time so stored values are robust against rate changes / model deprecation.
 *
 * @see .eval-loop/model-usage-stats/pricing.md for verified rates
 */

import type { Provider } from "./config.js";
import type { UsageEntry } from "./pipeline/history.js";
import { effectiveCatalog, findCatalogEntry, computeSummaryCost } from "./catalog.js";

export interface TranscriptionRate {
  ratePerMin: number;
}

export type ModelRate = TranscriptionRate;

export interface PricingSnapshot {
  pricedAsOf: string;
  models: Record<string, ModelRate>;
}

/**
 * Point-in-time transcription pricing keyed by registry model id.
 * Rates verified 2026-07-14.
 */
export const PRICING: PricingSnapshot = {
  pricedAsOf: "2026-07-14",
  models: {
    "universal":             { ratePerMin: 0.15 / 60 }, // $0.15/hr
    "whisper-1":             { ratePerMin: 0.006 },
    "gpt-4o-transcribe":     { ratePerMin: 0.006 },
    "gpt-4o-mini-transcribe": { ratePerMin: 0.003 },
  },
};

/**
 * Compute the USD cost of a usage entry.
 * - Transcription: uses the static PRICING table (duration-based).
 * - Summary: looks up the effective catalog for the model and computes
 *   tier-aware cost from token counts.
 * Returns `null` when the model is unknown or required inputs are absent.
 */
export function costForUsage(entry: UsageEntry): number | null {
  if (entry.task === "transcription") {
    const rate = PRICING.models[entry.modelId];
    if (!rate) return null;
    const { durationMin } = entry;
    if (durationMin === undefined) return null;
    return durationMin * rate.ratePerMin;
  }

  if (entry.task === "summary") {
    const { catalog } = effectiveCatalog();
    const catEntry = findCatalogEntry(catalog, entry.modelId);
    if (!catEntry) return null;
    const { tokensIn, tokensOut } = entry;
    if (tokensIn === undefined || tokensOut === undefined) return null;
    return computeSummaryCost(catEntry, tokensIn, tokensOut);
  }

  return null;
}

/**
 * Build a summary {@link UsageEntry} from raw token totals and compute its
 * cost from the effective catalog. Centralizes construction so callers
 * (orchestrator, re-summarize CLI) don't duplicate the wiring.
 */
export function makeSummaryUsage(
  modelId: string,
  provider: Provider,
  tokenUsage: { calls: number; tokensIn: number; tokensOut: number },
): UsageEntry {
  const { catalog } = effectiveCatalog();
  const catEntry = findCatalogEntry(catalog, modelId);
  const costUSD = catEntry
    ? computeSummaryCost(catEntry, tokenUsage.tokensIn, tokenUsage.tokensOut)
    : null;

  return {
    modelId,
    task: "summary",
    provider,
    calls: tokenUsage.calls,
    tokensIn: tokenUsage.tokensIn,
    tokensOut: tokenUsage.tokensOut,
    costUSD,
    pricedAsOf: catalog.fetchedAt,
    estimated: false,
  };
}
