import {
  DEFAULT_HISTORY_DIR,
  completeHistoryRecord,
  loadHistoryRecord,
} from "../pipeline/history.js";
import { isGeminiModel, summarizeTranscript } from "../pipeline/summarize.js";
import { defaultOutputPath, writeOutput } from "../pipeline/write.js";

export interface SummarizeHistoryOptions {
  model?: string;
  output?: string;
  force?: boolean;
  historyDir?: string;
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

  const model = options?.model ?? record.options?.model ?? "gpt-4o";
  const gemini = isGeminiModel(model);
  const apiKey = gemini
    ? process.env.GEMINI_API_KEY
    : process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error(
      gemini
        ? "GEMINI_API_KEY environment variable is required for gemini models. Get one at https://aistudio.google.com/apikey"
        : "OPENAI_API_KEY environment variable is required. Get one at https://platform.openai.com/api-keys",
    );
  }

  const segments =
    record.segments && record.segments.length > 0 ? record.segments : undefined;

  const summary = await summarizeTranscript(
    record.transcriptText,
    apiKey,
    model,
    segments,
  );

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

  await completeHistoryRecord(record.id, { summary, outputPath }, historyDir);

  process.stderr.write(`Summarized ${record.id} → ${outputPath}\n`);
  return outputPath;
}
