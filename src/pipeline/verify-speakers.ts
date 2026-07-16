import OpenAI from "openai";
import { isGeminiModel, GEMINI_OPENAI_BASE_URL } from "./summarize.js";
import type { TranscriptSegment } from "./transcribe.js";
import type { MatchResult, SpeakerDescription } from "./speakers.js";

// ── Types ────────────────────────────────────────────────────────

export type Verdict = "consistent" | "conflict" | "insufficient-evidence";

export interface LabelVerdict {
  label: string;
  verdict: Verdict;
  role?: string;
  evidence?: string;
}

export interface SpeakerContext {
  name: string;
  description?: SpeakerDescription;
}

export interface VerifyInput {
  segments: TranscriptSegment[];
  matches: Record<string, MatchResult>;
  speakerContexts: Record<string, SpeakerContext>;
  /** How many labels to verify at once. 0 = all. */
  limit?: number;
}

// ── Prompt builder ───────────────────────────────────────────────

export function buildVerifyPrompt(
  segments: TranscriptSegment[],
  matches: Record<string, MatchResult>,
  speakerContexts: Record<string, SpeakerContext>,
): string {
  const transcriptBody = segments
    .map((seg) => {
      const label = matches[seg.speaker ?? ""]?.name ?? seg.speaker ?? "Unknown";
      return `${label}: ${seg.text}`;
    })
    .join("\n");

  const profileLines = Object.entries(speakerContexts)
    .filter(([, ctx]) => !!ctx.description)
    .map(
      ([, ctx]) => `- **${ctx.name}**: ${ctx.description!.text}`,
    );

  const profileBlock =
    profileLines.length > 0
      ? `\n## Stored Speaker Profiles\n\n${profileLines.join("\n")}\n`
      : "";

  return `You are a speaker-label verifier. Your task is to judge whether each speaker's content in a transcript is consistent with their identity.

For each named speaker, produce one line of JSON with:
- verdict: "consistent" | "conflict" | "insufficient-evidence"
- role: a short generic role word inferred from content (e.g. "interviewer", "therapist", "customer", "presenter")
- evidence: a short verbatim quote from the transcript supporting a "conflict" verdict (omit for non-conflict verdicts)

Rules:
- NEVER guess or substitute a name. A "conflict" verdict must never rename.
- On "conflict": the speaker's statements contradict their stored description or are internally inconsistent with who they claim to be.
- On "conflict": demote only (do not rename).
- On "consistent": no action needed.
- On "insufficient-evidence": the transcript text doesn't provide enough content to judge.
- When a speaker has NO stored description, judge internal consistency only (is anything they say self-contradictory?).

Output exactly one JSON object line per named speaker, like:
{"label":"Speaker 1","verdict":"consistent","role":"interviewer"}
{"label":"Speaker 2","verdict":"conflict","evidence":"I don't work for Acme","role":"customer"}

Transcript:
${transcriptBody}
${profileBlock}
`;
}

// ── Response parser ──────────────────────────────────────────────

export function parseVerdicts(raw: string): LabelVerdict[] {
  const verdicts: LabelVerdict[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{")) continue;
    try {
      const parsed = JSON.parse(trimmed) as LabelVerdict;
      if (parsed.label && parsed.verdict) {
        verdicts.push(parsed);
      }
    } catch {
      // skip malformed lines
    }
  }
  return verdicts;
}

// ── Verifier ─────────────────────────────────────────────────────

export async function verifySpeakers(
  input: VerifyInput,
  apiKey: string,
  model: string = "gpt-5-mini",
  baseURL?: string,
): Promise<LabelVerdict[]> {
  const toCheck = Object.entries(input.matches).filter(
    ([, m]) => !m.tentative, // only check confident (non-tentative) matches
  );
  if (toCheck.length === 0) return [];

  const limited = input.limit ? toCheck.slice(0, input.limit) : toCheck;
  const relevantSegments = input.segments.filter((seg) =>
    limited.some(([label]) => seg.speaker === label),
  );

  const prompt = buildVerifyPrompt(relevantSegments, input.matches, input.speakerContexts);

  const client = new OpenAI({
    apiKey,
    baseURL: baseURL ?? (isGeminiModel(model) ? GEMINI_OPENAI_BASE_URL : undefined),
    maxRetries: 2,
  });

  try {
    const response = await client.chat.completions.create({
      model,
      messages: [{ role: "user", content: prompt }],
      temperature: 0,
      max_tokens: 1024,
    });

    const content = response.choices[0]?.message?.content;
    if (!content) return [];

    return parseVerdicts(content);
  } catch {
    // LLM failure = fail open. Never block the pipeline on a verification error.
    return [];
  }
}

// ── Apply verdicts ───────────────────────────────────────────────

export function applyVerdicts(
  matches: Record<string, MatchResult>,
  verdicts: LabelVerdict[],
): Record<string, MatchResult> {
  const updated = { ...matches };
  for (const v of verdicts) {
    if (v.verdict !== "conflict") continue;
    const match = updated[v.label];
    if (!match) continue;
    // Demote to tentative — the existing confirmation path surfaces it.
    updated[v.label] = {
      ...match,
      tentative: true,
    };
  }
  return updated;
}
