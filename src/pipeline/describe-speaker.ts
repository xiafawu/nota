import OpenAI from "openai";
import { isGeminiModel, GEMINI_OPENAI_BASE_URL } from "./summarize.js";
import type { TranscriptSegment } from "./transcribe.js";

// ── Types ────────────────────────────────────────────────────────

export interface SpeakerDescription {
  text: string;
  updatedAt: string;
  sourceHistoryIds: string[];
}

// ── Prompt builder ───────────────────────────────────────────────

export function buildDescriptionPrompt(
  name: string,
  segments: TranscriptSegment[],
): string {
  const transcriptBody = segments
    .map((seg) => `${seg.speaker ?? "Unknown"}: ${seg.text}`)
    .join("\n");

  return `Write a short entity description (1-3 sentences) for a speaker named "${name}" based on their transcript excerpts below.

Describe their typical role, recurring topics, and speaking style. Be factual and concise.

Transcript excerpts for ${name}:
${transcriptBody}
`;
}

// ── Description generator ────────────────────────────────────────

export async function generateDescription(
  name: string,
  segments: TranscriptSegment[],
  apiKey: string,
  model: string = "gpt-5-mini",
  baseURL?: string,
): Promise<string> {
  const prompt = buildDescriptionPrompt(name, segments);

  const client = new OpenAI({
    apiKey,
    baseURL: baseURL ?? (isGeminiModel(model) ? GEMINI_OPENAI_BASE_URL : undefined),
    maxRetries: 2,
  });

  const response = await client.chat.completions.create({
    model,
    messages: [{ role: "user", content: prompt }],
    temperature: 0.3,
    max_tokens: 256,
  });

  const content = response.choices[0]?.message?.content;
  if (!content) throw new Error("Empty response from description generation");
  return content.trim();
}
