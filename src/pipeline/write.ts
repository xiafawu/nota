import { writeFile } from "node:fs/promises";
import path from "node:path";
import type { TranscriptSegment } from "./transcribe.js";
import type { MeetingSummary } from "./summarize.js";
import type { HistoryKind, HistoryRecord } from "./history.js";
import { formatTimestamp } from "./transcribe.js";

export interface WriteInput {
  summary?: MeetingSummary;
  segments: TranscriptSegment[];
  capturedDate: string | null;
  transcribedDate: string;
  duration: number;
  source: string;
  /**
   * Markdown shape: `"memo"` renders the summary as a cleaned note
   * (`## Note` + optional `## Action Items`, no Key Topics/Decisions);
   * `"meeting"` (default) and `"file"` render the classic sections —
   * byte-identical to pre-kind output.
   */
  kind?: HistoryKind;
}

export function buildMarkdown(input: WriteInput): string {
  const { summary, segments, capturedDate, transcribedDate, duration, source, kind } = input;

  const title = summary?.title?.trim() || "Transcript";
  const tagsLine =
    summary?.tags && summary.tags.length > 0
      ? `\n**Tags:** ${summary.tags.join(", ")}`
      : "";
  const hasSummaryContent = summary?.narrative && summary.narrative.length > 0;

  const isMemo = kind === "memo";
  const actionLines = summary?.actionItems?.map((a) => `- ${a}`).join("\n") ?? "";
  const memoActionSection =
    actionLines.length > 0 ? `\n## Action Items\n\n${actionLines}\n` : "";
  const meetingSections = `\n## Key Topics\n\n${summary?.keyTopics?.map((t) => `- ${t}`).join("\n") ?? ""}\n\n## Decisions Made\n\n${summary?.decisions?.map((d) => `- ${d}`).join("\n") ?? ""}\n\n## Action Items\n\n${actionLines}\n`;
  const summarySection = hasSummaryContent
    ? isMemo
      ? `\n## Note\n\n${summary!.narrative}${memoActionSection}`
      : `\n## Summary\n\n${summary!.narrative}${meetingSections}`
    : "";

  const transcriptLines = segments
    .map((seg) => {
      const timestamp = formatTimestamp(seg.start);
      if (seg.speaker) {
        return `${timestamp} **${seg.speaker}:** ${seg.text}`;
      }
      return `${timestamp} ${seg.text}`;
    })
    .join("\n");

  return `# ${title}

**Captured:** ${capturedDate ?? "—"}
**Transcribed:** ${transcribedDate}
**Duration:** ${duration} minutes
**Source:** ${source}${tagsLine}
${summarySection}
---

## Full Transcript

${transcriptLines}
`;
}

export async function writeOutput(
  input: WriteInput,
  outputPath: string
): Promise<void> {
  const markdown = buildMarkdown(input);
  await writeFile(outputPath, markdown, "utf-8");
}

export function defaultOutputPath(inputPath: string): string {
  const dir = path.dirname(inputPath);
  const name = path.basename(inputPath, path.extname(inputPath));
  return path.join(dir, `${name}.summary.md`);
}

/**
 * Rewrite a record's markdown export from the record itself (record is truth,
 * E3-a — the `.md` is a derived export). Returns the path written. Callers
 * treat a failure here as a warning: the record was already persisted, and
 * the next successful save repairs the file.
 */
export async function writeOutputFromRecord(record: HistoryRecord): Promise<string> {
  const outputPath = record.outputPath ?? defaultOutputPath(record.sourcePath);
  await writeOutput(
    {
      summary: record.summary,
      segments: record.segments ?? [],
      capturedDate: record.capturedAt ? record.capturedAt.split("T")[0] : null,
      transcribedDate: record.createdAt.split("T")[0],
      duration: record.durationMinutes,
      source: record.sourceName,
      kind: record.kind,
    },
    outputPath,
  );
  return outputPath;
}
