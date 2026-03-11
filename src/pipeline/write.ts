import { writeFile } from "node:fs/promises";
import path from "node:path";
import type { TranscriptSegment } from "./transcribe.js";
import type { MeetingSummary } from "./summarize.js";
import { formatTimestamp } from "./transcribe.js";

export interface WriteInput {
  summary: MeetingSummary;
  segments: TranscriptSegment[];
  date: string;
  duration: number;
  source: string;
}

export function buildMarkdown(input: WriteInput): string {
  const { summary, segments, date, duration, source } = input;

  const topicLines = summary.keyTopics.map((t) => `- ${t}`).join("\n");
  const decisionLines = summary.decisions.map((d) => `- ${d}`).join("\n");
  const actionLines = summary.actionItems.map((a) => `- ${a}`).join("\n");
  const transcriptLines = segments
    .map((seg) => {
      const timestamp = formatTimestamp(seg.start);
      if (seg.speaker) {
        return `${timestamp} **${seg.speaker}:** ${seg.text}`;
      }
      return `${timestamp} ${seg.text}`;
    })
    .join("\n");

  return `# Meeting Summary

**Date:** ${date}
**Duration:** ${duration} minutes
**Source:** ${source}

## Summary

${summary.narrative}

## Key Topics

${topicLines}

## Decisions Made

${decisionLines}

## Action Items

${actionLines}

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
