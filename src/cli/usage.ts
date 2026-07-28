/**
 * CLI renderer for the `nota usage` command.
 *
 * Pure rendering over aggregators from {@link src/usage-stats.ts}.
 * No new computation — if a number needs deriving, it belongs in usage-stats,
 * not here.
 */
import type { AggregateWindow } from "../usage-stats.js";
import { perModelSummary, perRunLog } from "../usage-stats.js";
import { listHistoryRecords } from "../pipeline/history.js";
import { costNoteFor, effectiveCatalog } from "../catalog.js";

const VALID_WINDOWS = ["all", "30d", "month"] as const;

/**
 * Validate a --window argument. Returns the validated value or throws with a
 * descriptive error message listing valid values.
 */
export function parseWindow(value: string): AggregateWindow {
  const lower = value.toLowerCase();
  if (VALID_WINDOWS.includes(lower as AggregateWindow)) {
    return lower as AggregateWindow;
  }
  throw new Error(
    `Invalid window: "${value}". Valid values: ${VALID_WINDOWS.join(", ")}`,
  );
}

/**
 * Format a USD cost with enough precision for small values.
 * E.g. 0.0042 → "$0.0042", 1.5 → "$1.50", 0 → "$0.00".
 * Negative costs are treated as $0 (defensive).
 */
function formatCost(usd: number): string {
  if (usd < 0) return "$0.00";
  // For values < $0.01 show up to 4 decimal places to avoid $0.00 on tiny costs
  if (usd > 0 && usd < 0.01) {
    return `$${usd.toFixed(4)}`;
  }
  return `$${usd.toFixed(2)}`;
}


/**
 * `nota usage --json` — per-model summary as a JSON document.
 *
 * Returns the full JSON string. The caller (index.ts) writes it to stdout;
 * notes and errors remain on stderr.
 *
 * NOTE: --json with the `runs` subcommand is out of scope for T6:
 *   - `nota usage runs --json` → Commander errors (unknown option on subcommand)
 *   - `nota usage --json runs` → silently ignored (Commander consumes parent
 *     options then routes to subcommand, never executing this function)
 * Both forms are documented as unsupported; no code paths handle them.
 */
export async function usageSummaryJSON(window?: AggregateWindow, historyDir?: string): Promise<string> {
  const records = await listHistoryRecords(historyDir);
  const rows = records.length === 0 ? [] : perModelSummary(records, window);
  return JSON.stringify({ window: window ?? "all", rows });
}
/**
 * `nota usage` — per-model summary.
 * Tab-separated rows to stdout; headers, totals, and notes to stderr.
 */
export async function usageSummary(window?: AggregateWindow, historyDir?: string): Promise<void> {
  const records = await listHistoryRecords(historyDir);
  if (records.length === 0) {
    process.stderr.write("No usage data found.\n");
    return;
  }

  const rows = perModelSummary(records, window);

  if (rows.length === 0) {
    process.stderr.write("No usage data for the requested window.\n");
    return;
  }

  // A model Nota stores no pricing for is not a model of unknown cost: the
  // price exists, it just lives on the provider's dashboard. Print where to
  // look instead of a figure, and keep those runs out of the "unknown cost"
  // tally, which exists to flag gaps in *our* data.
  const { catalog: costCatalog } = effectiveCatalog();
  const notes = new Map<string, string | undefined>(
    rows.map((row) => [row.modelId, costNoteFor(costCatalog, row.modelId)]),
  );

  // Count unknown-cost rows
  let unknownCount = 0;
  for (const row of rows) {
    if (row.hasUnknown && notes.get(row.modelId) === undefined) {
      unknownCount += row.runs;
    }
  }

  // stderr: header + totals
  process.stderr.write("model\tprovider\truns\tcalls\ttokensIn\ttokensOut\tcostUSD\n");
  for (const row of rows) {
    const note = notes.get(row.modelId);
    const cost =
      note !== undefined
        ? note
        : row.hasUnknown && row.costUSD === 0
          ? "—"
          : formatCost(row.costUSD);
    const estMark = note !== undefined ? "" : row.hasEstimated ? "~" : "";
    const parts = [
      row.modelId,
      row.provider,
      String(row.runs),
      String(row.calls),
      String(row.tokensIn),
      String(row.tokensOut),
      `${estMark}${cost}`,
    ];
    process.stdout.write(`${parts.join("\t")}\n`);
  }

  // stderr: totals line
  const totalRuns = rows.reduce((s, r) => s + r.runs, 0);
  const totalCalls = rows.reduce((s, r) => s + r.calls, 0);
  const totalTokensIn = rows.reduce((s, r) => s + r.tokensIn, 0);
  const totalTokensOut = rows.reduce((s, r) => s + r.tokensOut, 0);
  const totalCost = rows.reduce((s, r) => s + r.costUSD, 0);
  const totalEstMark = rows.some((r) => r.hasEstimated) ? "~" : "";
  process.stderr.write("──\n");
  process.stderr.write(
    `total\t\t${totalRuns}\t${totalCalls}\t${totalTokensIn}\t${totalTokensOut}\t${totalEstMark}${formatCost(totalCost)}\n`,
  );
  if (unknownCount > 0) {
    process.stderr.write(`${unknownCount} runs have unknown cost\n`);
  }

  // Catalog pricing source footer
  const { catalog } = effectiveCatalog();
  process.stderr.write(`model catalog as of ${catalog.fetchedAt}\n`);
}

/**
 * `nota usage runs` — per-run cost log.
 * Tab-separated rows to stdout; headers, totals, and notes to stderr.
 */
export async function usageRuns(window?: AggregateWindow, historyDir?: string): Promise<void> {
  const records = await listHistoryRecords(historyDir);
  if (records.length === 0) {
    process.stderr.write("No usage data found.\n");
    return;
  }

  let filtered = records;
  if (window && window !== "all") {
    const now = Date.now();
    const cutoff = now - 30 * 24 * 60 * 60 * 1000;
    filtered = records.filter((r) => {
      const createdAt = new Date(r.createdAt).getTime();
      return createdAt >= cutoff;
    });
  }

  if (filtered.length === 0) {
    process.stderr.write("No usage data for the requested window.\n");
    return;
  }

  const rows = perRunLog(filtered);

  // Count runs with unknown cost
  let unknownCount = 0;
  for (const row of rows) {
    if (row.totalCostUSD === null) unknownCount++;
  }

  // stderr: header
  process.stderr.write("id\tdate\tmodels\tcostUSD\n");

  for (const row of rows) {
    const cost =
      row.totalCostUSD === null ? "—" : formatCost(row.totalCostUSD);
    const models = row.models.join(",");
    process.stdout.write(`${row.id}\t${row.createdAt.slice(0, 10)}\t${models}\t${cost}\n`);
  }

  // stderr: totals
  const totalCost = rows.reduce(
    (s, r) => s + (r.totalCostUSD === null ? 0 : r.totalCostUSD),
    0,
  );
  process.stderr.write("──\n");
  process.stderr.write(`total\t\t\t${formatCost(totalCost)}\n`);

  if (unknownCount > 0) {
    process.stderr.write(`${unknownCount} runs have unknown cost\n`);
  }

  // Catalog pricing source footer
  const { catalog } = effectiveCatalog();
  process.stderr.write(`model catalog as of ${catalog.fetchedAt}\n`);
}
