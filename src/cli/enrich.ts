import {
  DEFAULT_HISTORY_DIR,
  applyEnrichmentToRecord,
  loadHistoryRecord,
  mergeTags,
  setRecordSummary,
  setRecordTags,
  type EnrichmentPatch,
  type HistoryRecord,
} from "../pipeline/history.js";
import { makeSummaryUsage } from "../pricing.js";
import {
  generateTags,
  sampleTranscriptForTags,
  summarizeOnly,
  summarizeTranscript,
} from "../pipeline/summarize.js";
import { defaultOutputPath, writeOutputFromRecord } from "../pipeline/write.js";
import { DEFAULT_SUMMARY_MODEL, requireModel, type ModelEntry } from "../registry.js";
import { shouldChunkTranscript } from "../utils/tokens.js";
import { loadSettings, type NotaSettings } from "../utils/settings.js";

// Exit codes:
//   0 success
//   2 target field was manually edited and --force is absent
//   1 other

export class EnrichError extends Error {
  constructor(
    message: string,
    readonly exitCode: number = 1,
  ) {
    super(message);
    this.name = "EnrichError";
  }
}

export interface EnrichOptions {
  force?: boolean;
  historyDir?: string;
  /** Injectable for tests; loaded from disk otherwise. */
  settings?: NotaSettings;
}

/** Generation always uses the configured summary model (E1). */
function resolveSummaryModel(settings?: NotaSettings): ModelEntry {
  const resolved = settings ?? loadSettings();
  return requireModel(resolved.summary?.model ?? DEFAULT_SUMMARY_MODEL, "summary");
}

function requireApiKey(entry: ModelEntry): string {
  const apiKey = process.env[entry.apiKeyEnv];
  if (!apiKey) {
    throw new EnrichError(
      entry.provider === "gemini"
        ? `${entry.apiKeyEnv} environment variable is required for gemini models. Get one at https://aistudio.google.com/apikey`
        : `${entry.apiKeyEnv} environment variable is required. Get one at https://platform.openai.com/api-keys`,
    );
  }
  return apiKey;
}

/**
 * Record first, `.md` second (E3-f): by the time this runs the record is
 * already persisted, so a failed export only warns — the `.md` is always
 * regenerable from truth and the next successful save rewrites it.
 */
async function rewriteMarkdown(record: HistoryRecord): Promise<void> {
  try {
    await writeOutputFromRecord(record);
  } catch (error) {
    process.stderr.write(
      `Warning: failed to rewrite markdown for ${record.id}: ${
        error instanceof Error ? error.message : String(error)
      }\n`,
    );
  }
}

/**
 * `nota summarize <history-id>` — generate (or regenerate) the summary for a
 * saved transcript. Edited-is-protected: a hand-edited summary requires
 * --force (exit 2 otherwise). When the record's tags are edited, the E1
 * summary-only prompt runs and the tags stay untouched; otherwise the full
 * prompt regenerates tags too. Flips status to completed.
 */
export async function summarizeRecord(
  idOrPrefix: string,
  options?: EnrichOptions,
): Promise<HistoryRecord> {
  const historyDir = options?.historyDir ?? DEFAULT_HISTORY_DIR;
  const record = await loadHistoryRecord(idOrPrefix, historyDir);

  if (record.summaryEdited && !options?.force) {
    throw new EnrichError(
      `Summary of ${record.id} was edited by hand. Re-run with --force to replace it.`,
      2,
    );
  }

  const entry = resolveSummaryModel(options?.settings);
  const apiKey = requireApiKey(entry);
  const segments =
    record.segments && record.segments.length > 0 ? record.segments : undefined;

  // Edited tags are protected: regenerate without a tags section and keep the
  // record's tags verbatim (E1 summary-only op).
  const preserveTags = !!record.tagsEdited && (record.summary?.tags.length ?? 0) > 0;
  const { summary, tokenUsage } = preserveTags
    ? await summarizeOnly(record.transcriptText, apiKey, entry.wireId, segments, entry.baseURL)
    : await summarizeTranscript(record.transcriptText, apiKey, entry.wireId, segments, entry.baseURL);
  if (!summary.narrative.trim()) {
    throw new EnrichError("Summary model returned an empty summary; record left unchanged.");
  }
  if (preserveTags) summary.tags = record.summary!.tags;

  const usage = makeSummaryUsage(entry.id, record.provider, tokenUsage);
  const updated = await setRecordSummary(
    record.id,
    {
      summary,
      summaryEdited: false,
      // Freshly generated tags are no longer hand-edited; preserved tags keep
      // their flag so they stay protected.
      ...(preserveTags ? {} : { tagsEdited: false }),
      usage: [usage],
      outputPath: record.outputPath ?? defaultOutputPath(record.sourcePath),
    },
    historyDir,
  );
  await rewriteMarkdown(updated);
  return updated;
}

/**
 * E1 input ladder for tag generation: summary text when one exists (cheapest,
 * and tags describe what the user actually sees), else the whole transcript
 * when it fits, else evenly-sampled excerpts capped at ~50k tokens.
 */
function tagsSourceText(record: HistoryRecord): string {
  const summary = record.summary;
  if (summary && summary.narrative.trim().length > 0) {
    return [summary.narrative, ...(summary.keyTopics ?? [])].join("\n");
  }
  if (!shouldChunkTranscript(record.transcriptText)) {
    return record.transcriptText;
  }
  return sampleTranscriptForTags(record.transcriptText);
}

/**
 * `nota tag <history-id>` — generate tags and merge them with the record's
 * existing tags per E3-c (existing first, case-insensitive dedup, cap 8).
 * Hand-edited tags require --force (exit 2 otherwise); the merge keeps them
 * either way, so manual tags are never silently dropped. Status untouched.
 */
export async function tagRecord(
  idOrPrefix: string,
  options?: EnrichOptions,
): Promise<HistoryRecord> {
  const historyDir = options?.historyDir ?? DEFAULT_HISTORY_DIR;
  const record = await loadHistoryRecord(idOrPrefix, historyDir);

  if (record.tagsEdited && !options?.force) {
    throw new EnrichError(
      `Tags of ${record.id} were edited by hand. Re-run with --force to regenerate (manual tags are kept and merged).`,
      2,
    );
  }

  const entry = resolveSummaryModel(options?.settings);
  const apiKey = requireApiKey(entry);
  const { tags, tokenUsage } = await generateTags(
    tagsSourceText(record),
    apiKey,
    entry.wireId,
    entry.baseURL,
  );

  const usage = makeSummaryUsage(entry.id, record.provider, tokenUsage);
  const updated = await setRecordTags(
    record.id,
    { tags: mergeTags(record.summary?.tags ?? [], tags), usage: [usage] },
    historyDir,
  );
  await rewriteMarkdown(updated);
  return updated;
}

/** Parse and validate the stdin payload of `history apply-enrichment`. */
export function parseEnrichmentPayload(raw: string): EnrichmentPatch {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new EnrichError("apply-enrichment payload is not valid JSON");
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new EnrichError("apply-enrichment payload must be a JSON object");
  }
  const payload = parsed as Record<string, unknown>;
  const patch: EnrichmentPatch = {};
  if (payload.summary !== undefined) {
    if (typeof payload.summary !== "string") {
      throw new EnrichError("apply-enrichment payload.summary must be a string");
    }
    patch.summary = payload.summary;
  }
  if (payload.tags !== undefined) {
    if (
      !Array.isArray(payload.tags) ||
      payload.tags.some((tag) => typeof tag !== "string")
    ) {
      throw new EnrichError("apply-enrichment payload.tags must be an array of strings");
    }
    patch.tags = payload.tags as string[];
  }
  for (const flag of ["summaryEdited", "tagsEdited"] as const) {
    const value = payload[flag];
    if (value !== undefined) {
      if (typeof value !== "boolean") {
        throw new EnrichError(`apply-enrichment payload.${flag} must be a boolean`);
      }
      patch[flag] = value;
    }
  }
  return patch;
}

/**
 * `nota history apply-enrichment <history-id> --json` (hidden plumbing verb) —
 * apply a manual-edit patch from the macOS app: record first, `.md` second,
 * edited flags set exactly as given.
 */
export async function applyEnrichment(
  idOrPrefix: string,
  patch: EnrichmentPatch,
  options?: { historyDir?: string },
): Promise<HistoryRecord> {
  const historyDir = options?.historyDir ?? DEFAULT_HISTORY_DIR;
  const record = await loadHistoryRecord(idOrPrefix, historyDir);
  const updated = await applyEnrichmentToRecord(record.id, patch, historyDir);
  await rewriteMarkdown(updated);
  return updated;
}

/** Read all of stdin (the apply-enrichment JSON payload). */
export async function readStdinText(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString("utf-8");
}
