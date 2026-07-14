import OpenAI from "openai";
import { shouldChunkTranscript, splitTranscriptIntoSections } from "../utils/tokens.js";
import type { TranscriptSegment } from "./transcribe.js";

// The gemini base URL and provider check are owned by the model registry (the
// single source of truth). Re-exported here so existing importers keep working.
export { GEMINI_OPENAI_BASE_URL, isGeminiModel } from "../registry.js";
import { GEMINI_OPENAI_BASE_URL, isGeminiModel } from "../registry.js";

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

/**
 * The output-token cap parameter for a summary model, keyed correctly for its
 * provider. OpenAI chat models (incl. the gpt-5 reasoning family) require
 * `max_completion_tokens`; `max_tokens` is rejected outright by gpt-5*. Gemini's
 * OpenAI-compatible shim only understands `max_tokens` (it maps to Google's
 * maxOutputTokens), so branch on provider. Shared by the real summary call and
 * the preflight canary so the two request shapes can never drift.
 */
export function summaryTokenLimit(
  model: string,
  max: number,
): { max_tokens: number } | { max_completion_tokens: number } {
  return isGeminiModel(model)
    ? { max_tokens: max }
    : { max_completion_tokens: max };
}

async function callGPT(
  client: OpenAI,
  model: string,
  prompt: string
): Promise<string> {
  const response = await client.chat.completions.create({
    model,
    ...summaryTokenLimit(model, 4096),
    messages: [{ role: "user", content: prompt }],
  });

  const content = response.choices[0]?.message?.content;
  if (!content) throw new Error("Empty response from GPT");
  return content;
}

/**
 * Preflight canary for the summary model: the smallest possible real request
 * through the exact same client + params builder as {@link callGPT}, capped at
 * one output token. It exercises the request shape (the `max_completion_tokens`
 * vs `max_tokens` branch, model id, key, base URL) so a config-shape bug is
 * caught here — for ~free — instead of after a paid transcription. Throws the
 * provider's error on failure; the caller classifies it.
 */
export async function canarySummaryModel(
  apiKey: string,
  model: string,
  baseURL?: string,
): Promise<void> {
  const client = new OpenAI({
    apiKey,
    baseURL: baseURL ?? (isGeminiModel(model) ? GEMINI_OPENAI_BASE_URL : undefined),
    maxRetries: 0,
  });
  try {
    await client.chat.completions.create({
      model,
      ...summaryTokenLimit(model, 16),
      messages: [{ role: "user", content: "ping" }],
    });
  } catch (err) {
    // A reasoning model (gpt-5*) can exhaust a tiny output cap on reasoning
    // tokens and return a 400 "output limit reached". That means the request
    // shape, key, and reachability all passed — the call just truncated — so it
    // is a canary PASS. Only a genuine *shape/param/auth* rejection is a
    // failure, so rethrow everything that is not a truncation/length stop.
    if (isOutputLimitError(err)) return;
    throw err;
  }
}

/**
 * True when an OpenAI error signals the response was cut off by the token cap
 * (as opposed to the request being rejected). Distinguished from the real
 * "unsupported parameter" shape error, which must still fail the canary.
 */
export function isOutputLimitError(err: unknown): boolean {
  const message = err instanceof Error ? err.message : String(err);
  if (/unsupported parameter|is not supported|invalid|incorrect|authentica/i.test(message)) {
    return false;
  }
  return /output limit|could not finish|max_tokens.*reached|reached.*max_tokens|length limit|maximum context/i.test(
    message,
  );
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
