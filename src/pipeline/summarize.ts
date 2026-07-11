import OpenAI from "openai";
import { shouldChunkTranscript, splitTranscriptIntoSections } from "../utils/tokens.js";
import type { TranscriptSegment } from "./transcribe.js";

/**
 * Google's Gemini exposes an OpenAI-compatible endpoint, so the same OpenAI
 * client summarizes with Gemini by swapping the base URL and using a
 * `gemini-*` model with GEMINI_API_KEY. See
 * https://ai.google.dev/gemini-api/docs/openai
 */
export const GEMINI_OPENAI_BASE_URL =
  "https://generativelanguage.googleapis.com/v1beta/openai/";

/** True when a model name targets Gemini rather than OpenAI. */
export function isGeminiModel(model: string): boolean {
  return model.startsWith("gemini");
}

export interface MeetingSummary {
  title: string;
  tags: string[];
  narrative: string;
  keyTopics: string[];
  decisions: string[];
  actionItems: string[];
}

export function buildSpeakerLabeledTranscript(
  segments: TranscriptSegment[]
): string {
  return segments
    .map((seg) => {
      const prefix = seg.speaker ? `${seg.speaker}: ` : "";
      return `${prefix}${seg.text}`;
    })
    .join("\n");
}

export function buildSummaryPrompt(transcript: string, hasSpeakers: boolean = false): string {
  return `You are an expert meeting summarizer. Analyze the following meeting transcript and produce a structured summary.

## Transcript

${transcript}
${hasSpeakers ? "\nNote: The transcript includes speaker labels (Speaker 1, Speaker 2, etc.). Use these to attribute decisions, action items, and key points to specific speakers.\n" : ""}
## Instructions

Produce the following sections in your response. Use exactly these headers:

### Title
A concise, descriptive title for this meeting in at most 6 words. Plain text only — no quotes, no trailing punctuation.

### Summary
Write a concise 2-4 sentence narrative summary of the meeting.

### Key Topics
List each major topic discussed as a bullet point in the format:
- **Topic name** — brief description

### Decisions Made
List each decision made during the meeting:
- Decision — context and rationale

If no decisions were made, write "No explicit decisions were recorded."

### Action Items
List each action item as a checkbox:
- [ ] Action item — assigned to Person (if identifiable from the transcript)

If no action items were identified, write "No action items were identified."

### Tags
3 to 6 short, lowercase topical tags on a single line, comma-separated (for example: planning, roadmap, hiring).`;
}

function buildRollupPrompt(sectionSummaries: string[]): string {
  const combined = sectionSummaries
    .map((s, i) => `## Section ${i + 1}\n\n${s}`)
    .join("\n\n---\n\n");

  return `You are an expert meeting summarizer. The following are summaries of consecutive sections of a long meeting. Combine them into a single coherent summary.

${combined}

## Instructions

Produce a unified summary with these sections using exactly these headers:

### Title
A concise, descriptive title for the entire meeting in at most 6 words. Plain text only — no quotes, no trailing punctuation.

### Summary
Write a concise 2-4 sentence narrative summary of the entire meeting.

### Key Topics
Merge and deduplicate topics across all sections:
- **Topic name** — brief description

### Decisions Made
Merge all decisions:
- Decision — context and rationale

### Action Items
Merge all action items, deduplicating:
- [ ] Action item — assigned to Person

### Tags
3 to 6 short, lowercase topical tags on a single line, comma-separated (for example: planning, roadmap, hiring).`;
}

function cleanTitle(raw: string): string {
  const firstLine = raw.trim().split("\n").find((l) => l.trim().length > 0) ?? "";
  return firstLine
    .replace(/^[-*#\s]+/, "") // stray bullet/heading markers
    .replace(/^["'`]+|["'`]+$/g, "") // wrapping quotes
    .replace(/[.\s]+$/g, "") // trailing period/space
    .trim();
}

function parseTags(raw: string): string[] {
  const trimmed = raw.trim();
  if (!trimmed) return [];
  // Accept a comma-separated line or a bullet list.
  const tokens = trimmed.includes(",")
    ? trimmed.split(/[,\n]/)
    : trimmed.split("\n");
  return Array.from(
    new Set(
      tokens
        .map((t) => t.replace(/^[-*]\s*/, "").replace(/^#/, "").trim().toLowerCase())
        .filter((t) => t.length > 0)
    )
  ).slice(0, 8);
}

export function parseSummaryResponse(response: string): MeetingSummary {
  const sections = {
    title: "",
    tags: [] as string[],
    narrative: "",
    keyTopics: [] as string[],
    decisions: [] as string[],
    actionItems: [] as string[],
  };

  const titleMatch = response.match(/### Title\s*\n([\s\S]*?)(?=\n### |$)/);
  if (titleMatch) sections.title = cleanTitle(titleMatch[1]);

  const tagsMatch = response.match(/### Tags\s*\n([\s\S]*?)(?=\n### |$)/);
  if (tagsMatch) sections.tags = parseTags(tagsMatch[1]);

  const summaryMatch = response.match(
    /### Summary\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (summaryMatch) sections.narrative = summaryMatch[1].trim();

  const topicsMatch = response.match(
    /### Key Topics\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (topicsMatch) {
    sections.keyTopics = topicsMatch[1]
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2));
  }

  const decisionsMatch = response.match(
    /### Decisions Made\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (decisionsMatch) {
    sections.decisions = decisionsMatch[1]
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2));
  }

  const actionsMatch = response.match(
    /### Action Items\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (actionsMatch) {
    sections.actionItems = actionsMatch[1]
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2));
  }

  return sections;
}

async function callGPT(
  client: OpenAI,
  model: string,
  prompt: string
): Promise<string> {
  const response = await client.chat.completions.create({
    model,
    max_tokens: 4096,
    messages: [{ role: "user", content: prompt }],
  });

  const content = response.choices[0]?.message?.content;
  if (!content) throw new Error("Empty response from GPT");
  return content;
}

export async function summarizeTranscript(
  transcript: string,
  apiKey: string,
  model: string,
  segments?: TranscriptSegment[],
  baseURL?: string
): Promise<MeetingSummary> {
  const client = new OpenAI({
    apiKey,
    baseURL: baseURL ?? (isGeminiModel(model) ? GEMINI_OPENAI_BASE_URL : undefined),
  });

  const textToSummarize = segments
    ? buildSpeakerLabeledTranscript(segments)
    : transcript;

  if (!shouldChunkTranscript(textToSummarize)) {
    const prompt = buildSummaryPrompt(textToSummarize, !!segments);
    const response = await callGPT(client, model, prompt);
    return parseSummaryResponse(response);
  }

  // Long transcript: section-by-section then roll up
  const sections = splitTranscriptIntoSections(textToSummarize);
  const sectionSummaries: string[] = [];

  for (const section of sections) {
    const prompt = buildSummaryPrompt(section, !!segments);
    const response = await callGPT(client, model, prompt);
    sectionSummaries.push(response);
  }

  const rollupPrompt = buildRollupPrompt(sectionSummaries);
  const finalResponse = await callGPT(client, model, rollupPrompt);
  return parseSummaryResponse(finalResponse);
}
