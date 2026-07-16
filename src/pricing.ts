/**
 * Model pricing table — per-model rates for summary (per-token) and
 * transcription (per-duration) models. All USD. Point-in-time snapshot,
 * not a live source. Re-compute cost at write time so stored values are
 * robust against rate changes / model deprecation.
 *
 * @see .eval-loop/model-usage-stats/pricing.md for verified rates
 */

import type { Provider } from "./config.js";
import type { UsageEntry } from "./pipeline/history.js";

export interface SummaryRate {
  inputPer1M: number;
  outputPer1M: number;
  /** Tiered rate applies when prompt tokens exceed this threshold. */
  tierInputPer1M?: number;
  tierOutputPer1M?: number;
  tierThreshold?: number;
}

export interface TranscriptionRate {
  ratePerMin: number;
}

export type ModelRate = SummaryRate | TranscriptionRate;

export interface PricingSnapshot {
  pricedAsOf: string;
  models: Record<string, ModelRate>;
}

/**
 * Point-in-time pricing keyed by registry model id.
 * Rates verified 2026-07-14.
 */
export const PRICING: PricingSnapshot = {
  pricedAsOf: "2026-07-14",
  models: {
    // ── Summary models (per 1M tokens in / out) ──
    "gpt-5-mini":        { inputPer1M: 0.25, outputPer1M: 2.00 },
    "gpt-5":             { inputPer1M: 1.25, outputPer1M: 10.00 },
    "gpt-4o":            { inputPer1M: 2.50, outputPer1M: 10.00 },
    "gpt-4.1":           { inputPer1M: 2.00, outputPer1M: 8.00 },
    "gemini-2.5-flash":  { inputPer1M: 0.30, outputPer1M: 2.50 },
    "gemini-2.5-pro":    {
      inputPer1M: 1.25,
      outputPer1M: 10.00,
      tierInputPer1M: 2.50,
      tierOutputPer1M: 15.00,
      tierThreshold: 200_000,
    },
    // DeepSeek rates verified 2026-07-15 (cache-miss input rate; we don't
    // model prompt caching, so this over- rather than under-states cost).
    "deepseek-v4-flash": { inputPer1M: 0.14, outputPer1M: 0.28 },
    "deepseek-v4-pro":   { inputPer1M: 0.435, outputPer1M: 0.87 },
    // ── Transcription models (per minute) ──
    "universal":             { ratePerMin: 0.15 / 60 }, // $0.15/hr
    "whisper-1":             { ratePerMin: 0.006 },
    // TODO verify whisper-1 rate (page now foregrounds gpt-4o-transcribe at same rate)
    "gpt-4o-transcribe":     { ratePerMin: 0.006 },
    "gpt-4o-mini-transcribe": { ratePerMin: 0.003 },
  },
};

/**
 * Compute the USD cost of a usage entry using the point-in-time rate table.
 * Returns `null` when the model is unknown or required inputs are absent.
 */
export function costForUsage(entry: UsageEntry): number | null {
  const rate = PRICING.models[entry.modelId];
  if (!rate) return null;

  if (entry.task === "summary") {
    // Guard: the rate must be a SummaryRate (has inputPer1M)
    if (!("inputPer1M" in rate)) return null;
    const sr = rate as SummaryRate;
    const { tokensIn, tokensOut } = entry;
    if (tokensIn === undefined || tokensOut === undefined) return null;

    let inputRate = sr.inputPer1M;
    let outputRate = sr.outputPer1M;

    // gemini-2.5-pro tiered pricing: >200k prompt tokens
    if (sr.tierThreshold !== undefined && tokensIn > sr.tierThreshold) {
      if (sr.tierInputPer1M !== undefined) inputRate = sr.tierInputPer1M;
      if (sr.tierOutputPer1M !== undefined) outputRate = sr.tierOutputPer1M;
    }

    return (tokensIn / 1_000_000) * inputRate +
           (tokensOut / 1_000_000) * outputRate;
  }

  if (entry.task === "transcription") {
    // Guard: the rate must be a TranscriptionRate (has ratePerMin)
    if (!("ratePerMin" in rate)) return null;
    const tr = rate as TranscriptionRate;
    const { durationMin } = entry;
    if (durationMin === undefined) return null;
    return durationMin * tr.ratePerMin;
  }

  return null;
}

/**
 * Build a summary {@link UsageEntry} from raw token totals and compute its
 * cost. Centralizes construction so callers (orchestrator, re-summarize CLI)
 * don't duplicate the wiring.
 */
export function makeSummaryUsage(
  modelId: string,
  provider: Provider,
  tokenUsage: { calls: number; tokensIn: number; tokensOut: number },
): UsageEntry {
  const entry: UsageEntry = {
    modelId,
    task: "summary",
    provider,
    calls: tokenUsage.calls,
    tokensIn: tokenUsage.tokensIn,
    tokensOut: tokenUsage.tokensOut,
    costUSD: null,
    estimated: false,
  };
  entry.costUSD = costForUsage(entry);
  return entry;
}
