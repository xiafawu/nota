import OpenAI from "openai";
import {
  GEMINI_OPENAI_BASE_URL,
  isGeminiModel,
  usesMaxTokensParam,
} from "../registry.js";
import type { SpeakerDescription } from "./speakers.js";
import type { TranscriptSegment } from "./transcribe.js";

/** The two unresolved speaker cases shown to the user. */
export type SpeakerResolutionCategory =
  | "ambiguous-existing"
  | "new-unrecognized";

export interface AcousticSpeakerCandidate {
  name: string;
  confidence: number;
}

export interface SpeakerResolutionCandidate extends AcousticSpeakerCandidate {
  /** Short, model- or matcher-provided reason for showing this candidate. */
  evidence: string;
}

export interface SpeakerResolutionRecommendation {
  label: string;
  category: SpeakerResolutionCategory;
  candidates: SpeakerResolutionCandidate[];
  /** A contextual name suggestion for a new/unrecognized speaker. */
  proposedName?: string;
  confidence?: number;
  evidence?: string;
}

export interface SpeakerProfileContext {
  name: string;
  description?: SpeakerDescription;
}

export interface SpeakerRecommendationInput {
  transcript: TranscriptSegment[];
  labels: Array<{
    label: string;
    category: SpeakerResolutionCategory;
    acousticCandidates: AcousticSpeakerCandidate[];
  }>;
  profiles: SpeakerProfileContext[];
}

/**
 * Provider-agnostic seam for contextual speaker recommendations. Implementors
 * must return recommendations only; callers still require an explicit local
 * user choice before changing transcript labels or the voiceprint store.
 */
export interface SpeakerRecommendationProvider {
  recommend(
    input: SpeakerRecommendationInput,
  ): Promise<SpeakerResolutionRecommendation[]>;
}

export type CompleteSpeakerPrompt = (prompt: string) => Promise<string>;

function clampConfidence(value: unknown): number | undefined {
  if (typeof value !== "number" || !Number.isFinite(value)) return undefined;
  return Math.max(0, Math.min(1, value));
}

function cleanText(value: unknown, maxLength = 240): string | undefined {
  if (typeof value !== "string") return undefined;
  const text = value.replace(/\s+/g, " ").trim();
  return text ? text.slice(0, maxLength) : undefined;
}

function stripCodeFence(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.startsWith("```") && trimmed.endsWith("```")) {
    return trimmed
      .replace(/^```(?:json)?\s*/i, "")
      .replace(/\s*```$/, "")
      .trim();
  }
  return trimmed;
}

function parseObject(raw: string): unknown {
  const text = stripCodeFence(raw);
  try {
    return JSON.parse(text);
  } catch {
    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    if (start < 0 || end <= start) return null;
    try {
      return JSON.parse(text.slice(start, end + 1));
    } catch {
      return null;
    }
  }
}

function normalizeName(value: string): string {
  return value.trim().replace(/\s+/g, " ").toLocaleLowerCase();
}

function selfIntroductionNames(segments: TranscriptSegment[]): string[] {
  const names = new Set<string>();
  // This intentionally conservative recognizer is a safety gate, not a name
  // extractor for general text. A model proposal is accepted only when the
  // transcript itself contains a first-person introduction with that name.
  const patterns = [
    /\bmy name is\s+([A-Z][A-Za-z'’-]*(?:\s+[A-Z][A-Za-z'’-]*){0,2})/g,
    /\bI(?:'m| am)\s+([A-Z][A-Za-z'’-]*(?:\s+[A-Z][A-Za-z'’-]*){0,2})/g,
    /\bthis is\s+([A-Z][A-Za-z'’-]*(?:\s+[A-Z][A-Za-z'’-]*){0,2})/g,
  ];
  for (const segment of segments) {
    for (const pattern of patterns) {
      for (const match of segment.text.matchAll(pattern)) {
        const name = cleanText(match[1], 80);
        if (name) names.add(normalizeName(name));
      }
    }
  }
  return [...names];
}

function hasSelfIntroductionForName(
  proposedName: string,
  segments: TranscriptSegment[],
  label: string,
): boolean {
  return selfIntroductionNames(
    segments.filter((segment) => segment.speaker === label),
  ).includes(normalizeName(proposedName));
}

function profileSet(profiles: SpeakerProfileContext[]): Map<string, SpeakerProfileContext> {
  return new Map(profiles.map((profile) => [normalizeName(profile.name), profile]));
}

/**
 * Parse and constrain provider output. In particular, candidate names must
 * come from the enrolled profile set and new-speaker names must be evidenced
 * by an explicit self-introduction in the transcript.
 */
export function parseSpeakerRecommendations(
  raw: string,
  input: SpeakerRecommendationInput,
): SpeakerResolutionRecommendation[] {
  const parsed = parseObject(raw);
  const rows = Array.isArray((parsed as { resolutions?: unknown })?.resolutions)
    ? (parsed as { resolutions: unknown[] }).resolutions
    : [];
  const allowedLabels = new Map(input.labels.map((item) => [item.label, item]));
  const profiles = profileSet(input.profiles);
  const recommendations: SpeakerResolutionRecommendation[] = [];

  for (const row of rows) {
    if (!row || typeof row !== "object") continue;
    const value = row as Record<string, unknown>;
    const label = typeof value.label === "string" ? value.label : "";
    const request = allowedLabels.get(label);
    if (!request) continue;
    const category = value.category === "ambiguous-existing"
      ? "ambiguous-existing"
      : value.category === "new-unrecognized"
        ? "new-unrecognized"
        : request.category;

    const candidates: SpeakerResolutionCandidate[] = [];
    if (Array.isArray(value.candidates)) {
      for (const item of value.candidates) {
        if (!item || typeof item !== "object") continue;
        const candidate = item as Record<string, unknown>;
        if (typeof candidate.name !== "string") continue;
        const profile = profiles.get(normalizeName(candidate.name));
        if (!profile) continue;
        const confidence = clampConfidence(candidate.confidence);
        if (confidence === undefined) continue;
        candidates.push({
          name: profile.name,
          confidence,
          evidence: cleanText(candidate.evidence) ?? "Contextual recommendation",
        });
      }
    }
    const uniqueCandidates = [...new Map(
      candidates.map((candidate) => [normalizeName(candidate.name), candidate]),
    ).values()]
      .sort((a, b) => b.confidence - a.confidence)
      .slice(0, 3);

    const proposedName =
      typeof value.proposedName === "string" &&
      cleanText(value.proposedName, 80) &&
      hasSelfIntroductionForName(value.proposedName, input.transcript, label)
        ? cleanText(value.proposedName, 80)
        : undefined;

    recommendations.push({
      label,
      category,
      candidates: uniqueCandidates,
      proposedName,
      confidence: clampConfidence(value.confidence),
      evidence: cleanText(value.evidence),
    });
  }

  return recommendations;
}

export function buildSpeakerRecommendationPrompt(
  input: SpeakerRecommendationInput,
): string {
  const profileBlock = input.profiles.length > 0
    ? input.profiles
        .map((profile) => `- ${profile.name}${profile.description ? `: ${profile.description.text}` : ""}`)
        .join("\n")
    : "(no enrolled profiles)";
  const labelBlock = input.labels
    .map((item) => {
      const acoustic = item.acousticCandidates.length > 0
        ? item.acousticCandidates
            .slice(0, 3)
            .map((candidate) => `${candidate.name} (${Math.round(candidate.confidence * 100)}%)`)
            .join(", ")
        : "none above the acoustic tentative floor";
      return `- ${item.label} [${item.category}], acoustic candidates: ${acoustic}`;
    })
    .join("\n");
  const transcript = input.transcript
    .slice(0, 80)
    .map((segment) => `${segment.speaker ?? "Unknown"}: ${segment.text}`)
    .join("\n");

  return `You recommend resolutions for uncertain diarized speaker labels. You do not make final identity decisions.

Use only the enrolled profile names below for candidates. Rank up to three candidates for each ambiguous-existing label using the acoustic candidates and the transcript context. Give each candidate a confidence from 0 to 1 and concise evidence. For a new-unrecognized label, leave candidates empty unless the transcript context supports an existing profile; you may propose a new name only when that person explicitly self-introduces (for example, "my name is ..."), and never invent a name.

Enrolled profiles:
${profileBlock}

Uncertain labels:
${labelBlock}

Transcript context:
${transcript}

Return exactly one JSON object, with this shape:
{"resolutions":[{"label":"Speaker 1","category":"ambiguous-existing","candidates":[{"name":"Alice","confidence":0.62,"evidence":"..."}],"confidence":0.62,"evidence":"..."}]}
Allowed categories: "ambiguous-existing" or "new-unrecognized". Recommendations are advisory and require explicit user confirmation. No markdown.\n`;
}

export function createPromptSpeakerRecommendationProvider(
  complete: CompleteSpeakerPrompt,
): SpeakerRecommendationProvider {
  return {
    async recommend(input) {
      const raw = await complete(buildSpeakerRecommendationPrompt(input));
      return parseSpeakerRecommendations(raw, input);
    },
  };
}

/** Existing summary-provider adapter; no new credential or environment key. */
export function createOpenAISpeakerRecommendationProvider(
  apiKey: string,
  model: string,
  baseURL?: string,
): SpeakerRecommendationProvider {
  const client = new OpenAI({
    apiKey,
    baseURL: baseURL ?? (isGeminiModel(model) ? GEMINI_OPENAI_BASE_URL : undefined),
    maxRetries: 2,
  });
  return createPromptSpeakerRecommendationProvider(async (prompt) => {
    const response = await client.chat.completions.create({
      model,
      messages: [{ role: "user", content: prompt }],
      temperature: 0,
      ...(usesMaxTokensParam(model, baseURL)
        ? { max_tokens: 1400 }
        : { max_completion_tokens: 1400 }),
    });
    return response.choices[0]?.message?.content ?? "";
  });
}

/**
 * The pipeline's safe boundary: provider failures or malformed output produce
 * no contextual recommendation, allowing the local acoustic-choice flow to
 * continue without turning an LLM outage into an identity failure.
 */
export async function getContextualSpeakerRecommendations(
  input: SpeakerRecommendationInput,
  provider?: SpeakerRecommendationProvider,
): Promise<SpeakerResolutionRecommendation[]> {
  if (!provider || input.labels.length === 0) return [];
  try {
    return await provider.recommend(input);
  } catch {
    return [];
  }
}
