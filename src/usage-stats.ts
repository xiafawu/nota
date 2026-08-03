/**
 * Usage statistics aggregator — pure functions over {@link HistoryRecord[]}.
 * No rendering, no CLI wiring, no UI.
 *
 * @see PI-BUILD-SPEC.md §5 for the design spec
 */

import type { HistoryRecord } from "./pipeline/history.js";
import type { Provider } from "./config.js";
import { costForUsage } from "./pricing.js";
import { costNoteFor, effectiveCatalog } from "./catalog.js";

/** Aggregation window. */
export type AggregateWindow = "all" | "30d" | "7d" | "month";

/** One row in the per-model summary. */
export interface ModelSummaryRow {
  modelId: string;
  provider: Provider;
  runs: number;
  calls: number;
  tokensIn: number;
  tokensOut: number;
  costUSD: number;
  hasUnknown: boolean;
  /** True when any contribution to this row was estimated (e.g. legacy
   *  duration×rate reclamation) rather than API-reported. Display as `~`. */
  hasEstimated: boolean;
  /**
   * Present when Nota stores no pricing for this model (OpenRouter). Displays
   * print it *instead of* a dollar figure — the price exists, it just lives on
   * the provider's dashboard, which is a different thing from `hasUnknown`
   * (a gap in Nota's own data, rendered "—"). Computed here rather than in each
   * renderer so the CLI and the macOS dashboard cannot disagree.
   */
  costNote?: string;
}

/** One row in the per-run log. */
export interface RunLogRow {
  id: string;
  createdAt: string;
  models: string[];
  totalCostUSD: number | null;
}

/** Number of days in the "30d" window. */
const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000;
/** Number of days in the "7d" window. */
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;

function withinWindow(
  record: HistoryRecord,
  window: AggregateWindow | undefined,
  now: number,
): boolean {
  if (!window || window === "all") return true;
  const days = window === "7d" ? SEVEN_DAYS_MS : THIRTY_DAYS_MS;
  const cutoff = now - days;
  const createdAt = new Date(record.createdAt).getTime();
  // "month" — same as 30d for practical purposes (the build spec treats them
  // as equivalent; a calendar-month implementation can be substituted later).
  return createdAt >= cutoff;
}

/**
 * Summarize usage per model across a set of history records.
 *
 * Legacy records (without `usage`) are included with estimated costs:
 * transcription cost is reclaimed from `durationMinutes × rate`,
 * summary cost is null/unknown. Rows with null total cost are flagged via
 * `hasUnknown` so totals never silently understate.
 */
export function perModelSummary(
  records: HistoryRecord[],
  window?: AggregateWindow,
): ModelSummaryRow[] {
  const now = Date.now();
  const rows = new Map<string, ModelSummaryRow>();

  for (const record of records) {
    if (!withinWindow(record, window, now)) continue;

    if (!record.usage) {
      // Legacy record: infer transcription model from provider
      const transcriptionModel = record.provider === "assemblyai" ? "universal" : "whisper-1";
      const transcriptionCost = costForUsage({
        modelId: transcriptionModel,
        task: "transcription",
        provider: record.provider,
        calls: 1,
        durationMin: record.durationMinutes,
        costUSD: null,
        estimated: true,
      });

      // Legacy transcription — reclaimed via duration×rate, so estimated
      incrementRow(rows, transcriptionModel, record.provider, {
        runs: 1,
        calls: 1,
        costUSD: transcriptionCost ?? 0,
        hasUnknown: transcriptionCost === null,
        hasEstimated: transcriptionCost !== null,
      });

      // Legacy summary — cost unknown
      incrementRow(rows, "summary", record.provider, {
        runs: 1,
        calls: 0,
        costUSD: 0,
        hasUnknown: true,
        hasEstimated: false,
      });

      continue;
    }


    // Records with usage entries — sum costs/tokens across all entries,
    // but count `runs` only once per (modelId, provider, record.id).
    const runsCounted = new Set<string>();
    for (const u of record.usage) {
      const rowKey = `${u.modelId}::${u.provider}`;
      const runKey = `${rowKey}::${record.id}`;

      incrementRow(rows, u.modelId, u.provider, {
        runs: runsCounted.has(runKey) ? 0 : 1,
        calls: u.calls,
        costUSD: u.costUSD ?? 0,
        hasUnknown: u.costUSD === null,
        hasEstimated: u.estimated && u.costUSD !== null,
        tokensIn: u.tokensIn ?? 0,
        tokensOut: u.tokensOut ?? 0,
      });
      runsCounted.add(runKey);
    }
  }

  // A row is keyed by model id, so the note is a pure function of the finished
  // row — annotating once here beats threading it through every increment.
  const { catalog } = effectiveCatalog();
  for (const row of rows.values()) {
    const note = costNoteFor(catalog, row.modelId);
    if (note !== undefined) row.costNote = note;
  }

  return [...rows.values()].sort((a, b) => b.costUSD - a.costUSD);
}

interface IncrementOpts {
  runs: number;
  calls: number;
  costUSD: number;
  hasUnknown: boolean;
  hasEstimated: boolean;
  tokensIn?: number;
  tokensOut?: number;
}

function incrementRow(
  rows: Map<string, ModelSummaryRow>,
  modelId: string,
  provider: Provider,
  opts: IncrementOpts,
): void {
  const key = modelId;
  const existing = rows.get(key);
  if (existing) {
    existing.runs += opts.runs;
    existing.calls += opts.calls;
    existing.tokensIn += opts.tokensIn ?? 0;
    existing.tokensOut += opts.tokensOut ?? 0;
    existing.costUSD += opts.costUSD;
    if (opts.hasUnknown) existing.hasUnknown = true;
    if (opts.hasEstimated) existing.hasEstimated = true;
  } else {
    rows.set(key, {
      modelId,
      provider,
      runs: opts.runs,
      calls: opts.calls,
      tokensIn: opts.tokensIn ?? 0,
      tokensOut: opts.tokensOut ?? 0,
      costUSD: opts.costUSD,
      hasUnknown: opts.hasUnknown,
      hasEstimated: opts.hasEstimated,
    });
  }
}

/**
 * Per-run log of usage, ordered by newest first.
 * Legacy rows (no `usage`) get estimated transcription cost from
 * `durationMinutes × rate`; summary cost remains `null`.
 */
export function perRunLog(records: HistoryRecord[]): RunLogRow[] {
  const rows: RunLogRow[] = [];

  for (const record of records) {
    if (!record.usage) {
      // Legacy: reclaim transcription cost
      const transcriptionModel = record.provider === "assemblyai" ? "universal" : "whisper-1";
      const transcriptionCost = costForUsage({
        modelId: transcriptionModel,
        task: "transcription",
        provider: record.provider,
        calls: 1,
        durationMin: record.durationMinutes,
        costUSD: null,
        estimated: true,
      });

      rows.push({
        id: record.id,
        createdAt: record.createdAt,
        models: [transcriptionModel],
        totalCostUSD: transcriptionCost, // null when unknown
      });
      continue;
    }

    const models = new Set<string>();
    let totalCost = 0;
    let hasNull = false;

    for (const u of record.usage) {
      models.add(u.modelId);
      if (u.costUSD !== null) {
        totalCost += u.costUSD;
      } else {
        hasNull = true;
      }
    }

    rows.push({
      id: record.id,
      createdAt: record.createdAt,
      models: [...models],
      totalCostUSD: hasNull ? null : totalCost,
    });
  }

  return rows.sort(
    (a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime(),
  );
}
