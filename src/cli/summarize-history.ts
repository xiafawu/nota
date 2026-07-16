import {
  DEFAULT_HISTORY_DIR,
  completeHistoryRecord,
  loadHistoryRecord,
  type UsageEntry,
} from "../pipeline/history.js";
import { makeSummaryUsage } from "../pricing.js";
import { summarizeTranscript } from "../pipeline/summarize.js";
import { defaultOutputPath, writeOutput } from "../pipeline/write.js";
import { DEFAULT_SUMMARY_MODEL, getModel, requireModel } from "../registry.js";
import { loadSettings, type NotaSettings } from "../utils/settings.js";

export interface SummarizeHistoryOptions {
  model?: string;
  output?: string;
  force?: boolean;
  historyDir?: string;
  /** Injectable for tests; loaded from disk otherwise. */
  settings?: NotaSettings;
}

/** True only when `id` is a known summary model in the registry. */
function validSummaryModel(id: string | undefined): id is string {
  return !!id && getModel(id)?.task === "summary";
}

export async function summarizeHistory(
  idOrPrefix: string,
  options?: SummarizeHistoryOptions,
): Promise<string> {
  const historyDir = options?.historyDir ?? DEFAULT_HISTORY_DIR;
  const record = await loadHistoryRecord(idOrPrefix, historyDir);

  if (record.status === "completed" && !options?.force) {
    const existing = record.outputPath ?? "";
    process.stderr.write(
      `Record ${record.id} already summarized → ${existing}. ` +
        `Re-run with --force to regenerate.\n`,
    );
    return existing;
  }

  // Precedence: explicit -m > the model the record was made with (when still a
  // valid summary model) > settings.summary.model > built-in default.
  const settings = options?.settings ?? loadSettings();
  const modelId =
    options?.model ??
    (validSummaryModel(record.options?.model)
      ? record.options!.model!
      : undefined) ??
    settings.summary?.model ??
    DEFAULT_SUMMARY_MODEL;

  // Registry is the single source of truth for provider, key, and base URL.
  const entry = requireModel(modelId, "summary");
  const apiKey = process.env[entry.apiKeyEnv];
  if (!apiKey) {
    throw new Error(
      entry.provider === "gemini"
        ? `${entry.apiKeyEnv} environment variable is required for gemini models. Get one at https://aistudio.google.com/apikey`
        : `${entry.apiKeyEnv} environment variable is required. Get one at https://platform.openai.com/api-keys`,
    );
  }

  const segments =
    record.segments && record.segments.length > 0 ? record.segments : undefined;

  const { summary, tokenUsage } = await summarizeTranscript(
    record.transcriptText,
    apiKey,
    entry.id,
    segments,
    entry.baseURL,
  );
  const summaryUsage = makeSummaryUsage(entry.id, record.provider, tokenUsage);

  const transcribedDate = new Date().toISOString().split("T")[0];
  const capturedDate = record.capturedAt
    ? record.capturedAt.split("T")[0]
    : null;
  const outputPath =
    options?.output ??
    record.outputPath ??
    defaultOutputPath(record.sourcePath);

  await writeOutput(
    {
      summary,
      segments: record.segments ?? [],
      capturedDate,
      transcribedDate,
      duration: record.durationMinutes,
      source: record.sourceName,
    },
    outputPath,
  );

  await completeHistoryRecord(record.id, { summary, outputPath, usage: [summaryUsage] }, historyDir);

  process.stderr.write(`Summarized ${record.id} → ${outputPath}\n`);
  return outputPath;
}
