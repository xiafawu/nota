import { readFile, writeFile, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import type { TranscriptSegment } from "./transcribe.js";
import { cosine, MATCH_THRESHOLD, TENTATIVE_THRESHOLD } from "./embed.js";
import type {
  AcousticSpeakerCandidate,
  SpeakerResolutionRecommendation,
} from "./contextual-speakers.js";

const SPEAKERS_DIR = path.join(homedir(), ".nota");
const LEGACY_SPEAKERS_FILE = path.join(homedir(), ".meetingsum", "speakers.json");
const SPEAKERS_FILE = path.join(SPEAKERS_DIR, "speakers.json");

export const DEFAULT_SPEAKERS_FILE = SPEAKERS_FILE;
export const DEFAULT_LEGACY_SPEAKERS_FILE = LEGACY_SPEAKERS_FILE;

export type MatchResult = { name: string; confidence: number; tentative?: boolean };

// Schema v4: one name maps to N ONNX d-vector voiceprints (one per enrollment
// event). Matching scores a label embedding against every voiceprint, so
// adding voiceprints can only help recall.
export interface Voiceprint {
  /** ISO timestamp of enrollment — also serves as stable CLI handle. */
  id: string;
  /** L2-normalized ONNX speaker embedding. */
  embedding: number[];
  enrolledAt: string;
  source: string;
  /**
   * True when this voiceprint disagreed strongly with the person's existing
   * prints at enrollment time (see {@link enrollVoiceprintWithCheck}).
   * Optional: legacy voiceprints predate the flag; absent means no flag.
   */
  lowAgreement?: boolean;
}

export interface SpeakerDescription {
  text: string;
  updatedAt: string;
  sourceHistoryIds: string[];
}

export interface SpeakerProfile {
  voiceprints: Voiceprint[];
  description?: SpeakerDescription;
}

export interface SpeakerStore {
  version: number;
  speakers: Record<string, SpeakerProfile>;
}

const STORE_VERSION = 4;

export async function loadProfiles(
  filePath: string = SPEAKERS_FILE,
): Promise<SpeakerStore> {
  const read = async (p: string): Promise<unknown> =>
    JSON.parse(await readFile(p, "utf-8"));

  let raw: unknown;
  try {
    raw = await read(filePath);
  } catch {
    if (filePath === SPEAKERS_FILE) {
      try {
        raw = await read(LEGACY_SPEAKERS_FILE);
      } catch {
        raw = null;
      }
    }
  }
  if (!raw || typeof raw !== "object") {
    return { version: STORE_VERSION, speakers: {} };
  }

  // Keep only v4-shaped voiceprints carrying a non-empty numeric embedding.
  const speakersRaw = (raw as { speakers?: Record<string, unknown> }).speakers ?? {};
  const speakers: Record<string, SpeakerProfile> = {};
  let dropped = 0;
  for (const [name, profile] of Object.entries(speakersRaw)) {
    const rawVoiceprints = (profile as { voiceprints?: unknown })?.voiceprints;
    const voiceprints = Array.isArray(rawVoiceprints) ? rawVoiceprints : [];
    dropped += voiceprints.filter(
      (vp) => typeof (vp as { profile?: unknown })?.profile === "string",
    ).length;
    const vps = voiceprints.filter(
      (vp): vp is Voiceprint => {
        const embedding = (vp as Partial<Voiceprint>)?.embedding;
        return (
          Array.isArray(embedding) &&
          embedding.length > 0 &&
          embedding.every((value) => typeof value === "number" && Number.isFinite(value))
        );
      },
    );
    if (vps.length === 0) continue;
    const rawDescription = (profile as { description?: unknown })?.description;
    const description =
      rawDescription && typeof rawDescription === "object" &&
      typeof (rawDescription as { text?: unknown }).text === "string"
        ? {
            text: (rawDescription as { text: string }).text,
            updatedAt:
              typeof (rawDescription as { updatedAt?: unknown }).updatedAt === "string"
                ? (rawDescription as { updatedAt: string }).updatedAt
                : "",
            sourceHistoryIds: Array.isArray(
              (rawDescription as { sourceHistoryIds?: unknown }).sourceHistoryIds,
            )
              ? (rawDescription as { sourceHistoryIds: unknown[] }).sourceHistoryIds.filter(
                  (id): id is string => typeof id === "string",
                )
              : [],
          }
        : undefined;
    speakers[name] = description
      ? { voiceprints: vps, description }
      : { voiceprints: vps };
  }
  if (dropped > 0) {
    process.stderr.write(
      `dropped ${dropped} Eagle speaker profile(s) incompatible with the ONNX backend; re-enroll to restore.\n`,
    );
  }
  return { version: STORE_VERSION, speakers };
}

export async function saveProfiles(
  store: SpeakerStore,
  filePath: string = SPEAKERS_FILE,
): Promise<void> {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, JSON.stringify(store, null, 2), "utf-8");
}
/**
 * Minimum gap between top-1 and top-2 for the same label to claim a match
 * (open-set rejection). Prevents an unenrolled speaker from being absorbed
 * into the nearest enrolled profile. Overridable via NOTA_MATCH_MARGIN.
 */
export const MATCH_MARGIN = parseFloat(process.env.NOTA_MATCH_MARGIN ?? "") || 0.06;

/**
 * Assign enrolled names to diarized labels from a per-label score vector.
 * `scoredByLabel[label][i]` is the cosine score of `label` against the
 * i-th enrolled voiceprint; `names[i]` is the speaker name that voiceprint
 * belongs to. Greedy global assignment: sort every (label, voiceprint)
 * candidate at/above the tentative floor by score, then claim each label and
 * each name at most once. A claim at/above MATCH_THRESHOLD is confident; in
 * `[TENTATIVE_THRESHOLD, MATCH_THRESHOLD)` it is tentative (caller confirms).
 *
 * ### Open-set rejection (margin gate)
 * A label is only claimed if the top-1 score exceeds the second-best by at
 * least {@link MATCH_MARGIN}. This prevents an unenrolled speaker from being
 * absorbed into the nearest enrolled profile — without this gate, any
 * embedding above threshold gets a name even if it is nearly equidistant from
 * two profiles, which produces false positive matches for out-of-set voices.
 */
export function rankMatches(
  scoredByLabel: Record<string, number[]>,
  names: string[],
): Record<string, MatchResult> {
  const candidates: { label: string; name: string; score: number }[] = [];
  for (const [label, scores] of Object.entries(scoredByLabel)) {
    // Find top-2 scores for this label to apply the margin gate
    let top1 = -Infinity;
    let top1Name = "";
    let top2 = -Infinity;
    for (let i = 0; i < scores.length; i++) {
      if (scores[i] < TENTATIVE_THRESHOLD) continue;
      if (names[i] === undefined) continue;
      if (scores[i] > top1) {
        top2 = top1;
        top1 = scores[i];
        top1Name = names[i];
      } else if (scores[i] > top2) {
        top2 = scores[i];
      }
    }

    // Margin gate: skip this label if the gap to second-best is too small
    // (open-set rejection — no single profile is clearly the match).
    if (top1 - top2 < MATCH_MARGIN) continue;

    // Emit all qualified candidates above threshold for this label
    for (let i = 0; i < scores.length; i++) {
      if (scores[i] >= TENTATIVE_THRESHOLD && names[i] !== undefined) {
        candidates.push({ label, name: names[i], score: scores[i] });
      }
    }
  }
  candidates.sort((a, b) => b.score - a.score);

  const out: Record<string, MatchResult> = {};
  const claimedNames = new Set<string>();
  for (const { label, name, score } of candidates) {
    if (out[label] || claimedNames.has(name)) continue;
    out[label] =
      score >= MATCH_THRESHOLD
        ? { name, confidence: score }
        : { name, confidence: score, tentative: true };
    claimedNames.add(name);
  }
  return out;
}

/**
 * Match label embeddings against all enrolled voiceprints, then resolve names
 * with `rankMatches`. Duplicate names in the flattened candidates make the
 * highest-scoring voiceprint for that name win effectively.
 */
export function matchProfiles(
  labelEmbeddings: Record<string, number[]>,
  store: SpeakerStore,
): Record<string, MatchResult> {
  const names: string[] = [];
  const embeddings: number[][] = [];
  for (const [name, profile] of Object.entries(store.speakers)) {
    for (const vp of profile.voiceprints) {
      names.push(name);
      embeddings.push(vp.embedding);
    }
  }
  if (embeddings.length === 0) return {};

  const scoredByLabel: Record<string, number[]> = {};
  for (const [label, embedding] of Object.entries(labelEmbeddings)) {
    scoredByLabel[label] = embeddings.map((voiceprint) => cosine(embedding, voiceprint));
  }
  return rankMatches(scoredByLabel, names);
}

/**
 * Return the best acoustic score for each enrolled profile. Unlike
 * `matchProfiles`, this preserves a ranked candidate set for the explicit
 * ambiguity UI and contextual recommender.
 */
export function rankProfileCandidates(
  labelEmbeddings: Record<string, number[]>,
  store: SpeakerStore,
  limit = 3,
): Record<string, AcousticSpeakerCandidate[]> {
  const out: Record<string, AcousticSpeakerCandidate[]> = {};
  for (const [label, embedding] of Object.entries(labelEmbeddings)) {
    const candidates: AcousticSpeakerCandidate[] = [];
    for (const [name, profile] of Object.entries(store.speakers)) {
      const confidence = profile.voiceprints.reduce(
        (best, voiceprint) => Math.max(best, cosine(embedding, voiceprint.embedding)),
        -Infinity,
      );
      if (Number.isFinite(confidence)) candidates.push({ name, confidence });
    }
    out[label] = candidates.sort((a, b) => b.confidence - a.confidence).slice(0, limit);
  }
  return out;
}

/**
 * Minimum same-name cosine for a new voiceprint to be considered consistent
 * with the person's existing prints at enrollment time. A new print scoring
 * below this against every existing print of the same person is flagged
 * `lowAgreement` (warn, never refuse). From docs/research/voiceprint-cosine-bands.md:
 * same-name enrollment pairs span 0.025–0.623 (Brian's pair is 0.025), so a
 * print this far from its own name is near-certainly enrollment-condition
 * garbage.
 */
export const LOW_AGREEMENT_WARN_THRESHOLD =
  parseFloat(process.env.NOTA_LOW_AGREEMENT_WARN ?? "") || 0.5;

/**
 * Doctor-report floor for same-name voiceprint pairs (see decision 6 of the
 * speaker-workflow spec): `nota speakers doctor` lists every same-name pair
 * scoring below this, flagged or not, so legacy garbage pairs surface too.
 */
export const LOW_AGREEMENT_FLOOR =
  parseFloat(process.env.NOTA_LOW_AGREEMENT_FLOOR ?? "") || 0.3;

export type SuggestionState = "pending" | "accepted" | "dismissed";

/**
 * A tentative-band speaker suggestion persisted on a history record. For each
 * diarized label whose best cosine against an enrolled voiceprint lands in
 * [TENTATIVE_THRESHOLD, MATCH_THRESHOLD), the record carries one of these so
 * the macOS chip can offer accept/dismiss without re-running recognition.
 * Confident matches auto-label and never produce a suggestion.
 */
export interface SpeakerSuggestion {
  /** Diarized label on the record (e.g. "Speaker 2"). */
  label: string;
  /** Enrolled speaker name the label best matches. */
  suggestedName: string;
  /** Best cosine of the label's clip against `voiceprintId`. */
  score: number;
  /** Id of the voiceprint that produced the best score. */
  voiceprintId: string;
  state: SuggestionState;
  /** ISO timestamp when accepted/dismissed; absent while pending. */
  decidedAt?: string;
}

/**
 * Compute tentative-band suggestions per label. Independent of
 * `rankMatches`' global name claiming: each label's best candidate is
 * evaluated on its own, so two labels can each suggest the same name (both
 * may later be accepted — renaming allows merging into one person). A label
 * is suggested only when its best score is in [TENTATIVE, MATCH); confident
 * and below-floor labels never produce one.
 */
export function computeSuggestions(
  labelEmbeddings: Record<string, number[]>,
  store: SpeakerStore,
): SpeakerSuggestion[] {
  const suggestions: SpeakerSuggestion[] = [];
  for (const [label, embedding] of Object.entries(labelEmbeddings)) {
    let bestName: string | undefined;
    let bestVoiceprintId = "";
    let bestScore = -Infinity;
    for (const [name, profile] of Object.entries(store.speakers)) {
      for (const vp of profile.voiceprints) {
        const score = cosine(embedding, vp.embedding);
        if (score > bestScore) {
          bestScore = score;
          bestName = name;
          bestVoiceprintId = vp.id;
        }
      }
    }
    if (
      bestName === undefined ||
      bestScore < TENTATIVE_THRESHOLD ||
      bestScore >= MATCH_THRESHOLD
    ) {
      continue;
    }
    suggestions.push({
      label,
      suggestedName: bestName,
      score: bestScore,
      voiceprintId: bestVoiceprintId,
      state: "pending",
    });
  }
  return suggestions.sort((a, b) => a.label.localeCompare(b.label));
}

export interface EnrollOutcome {
  /** The new voiceprint (already appended to the store). */
  voiceprint: Voiceprint;
  /**
   * Best cosine of the new embedding against the person's pre-existing
   * voiceprints; `null` for a first enrollment (nothing to compare).
   */
  agreement: number | null;
  /** True when the new print was flagged `lowAgreement`. */
  lowAgreement: boolean;
}

/**
 * Enrollment hygiene (decision 6): append a voiceprint to `name`'s profile,
 * comparing the new embedding against the person's existing prints first.
 * Strong disagreement (best same-name cosine below
 * {@link LOW_AGREEMENT_WARN_THRESHOLD}) warns on stderr naming the score and
 * marks the new print `lowAgreement: true` — never refuses, never silent.
 * A first enrollment has nothing to compare and is never flagged.
 */
export function enrollVoiceprintWithCheck(
  store: SpeakerStore,
  name: string,
  embedding: number[],
  source: string,
): EnrollOutcome {
  const now = new Date().toISOString();
  const existing = store.speakers[name]?.voiceprints ?? [];
  let agreement: number | null = null;
  for (const vp of existing) {
    const score = cosine(embedding, vp.embedding);
    agreement = agreement === null ? score : Math.max(agreement, score);
  }
  const lowAgreement =
    agreement !== null && agreement < LOW_AGREEMENT_WARN_THRESHOLD;
  const voiceprint: Voiceprint = {
    id: now,
    embedding,
    enrolledAt: now,
    source,
    ...(lowAgreement ? { lowAgreement: true } : {}),
  };
  if (store.speakers[name]) store.speakers[name].voiceprints.push(voiceprint);
  else store.speakers[name] = { voiceprints: [voiceprint] };
  if (lowAgreement) {
    process.stderr.write(
      `Warning: new voiceprint for "${name}" scores ${agreement!.toFixed(3)} ` +
        `against the best existing voiceprint — strongly inconsistent. ` +
        `Marked lowAgreement; see \`nota speakers doctor\`.\n`,
    );
  }
  return { voiceprint, agreement, lowAgreement };
}

export interface TentativeMatch {
  name: string;
  confidence: number;
}

export interface PromptResult {
  // Names assigned by the user this session. Includes both confirmed
  // tentative matches (existing profile, no re-enroll) and brand-new
  // names entered fresh.
  names: Record<string, string>;
  // Subset of `names` that came from a fresh prompt, i.e. the user typed
  // a new name (not a tentative confirmation). Caller uses this to decide
  // which labels to enroll into the profile store.
  enroll: Record<string, string>;
  // Explicit user corrections selecting an enrolled candidate. The caller
  // may learn these as an additional voiceprint after checking clip quality.
  learn?: Record<string, string>;
}

export interface SpeakerPromptOptions {
  ask?: (question: string) => Promise<string>;
  write?: (message: string) => void;
}

function collectSpeakerSamples(
  segments: TranscriptSegment[],
  labels: string[],
): Record<string, string[]> {
  const samples: Record<string, string[]> = {};
  for (const seg of segments) {
    if (!seg.speaker || !labels.includes(seg.speaker)) continue;
    if (!samples[seg.speaker]) samples[seg.speaker] = [];
    if (samples[seg.speaker].length < 3) samples[seg.speaker].push(seg.text);
  }
  return samples;
}

function printSpeakerSamples(
  write: (message: string) => void,
  label: string,
  samples: Record<string, string[]>,
): void {
  write(`${label} said:`);
  for (const sample of samples[label] ?? []) write(`  "${sample}"`);
}

/**
 * Explicit local resolution UI for the hybrid path. Every recommendation is
 * advisory: selecting an enrolled candidate is a user correction, while a
 * new name is only enrolled after the user explicitly accepts or enters it.
 */
export async function promptForSpeakerResolutions(
  segments: TranscriptSegment[],
  recommendations: SpeakerResolutionRecommendation[],
  options: SpeakerPromptOptions = {},
): Promise<PromptResult> {
  const rl = options.ask
    ? undefined
    : createInterface({ input: process.stdin, output: process.stderr });
  const write = options.write ?? ((message: string) => console.error(message));
  const ask = options.ask ?? ((question: string) =>
    new Promise<string>((resolve) => rl!.question(question, resolve)));
  const samples = collectSpeakerSamples(
    segments,
    recommendations.map((recommendation) => recommendation.label),
  );
  const names: Record<string, string> = {};
  const enroll: Record<string, string> = {};
  const learn: Record<string, string> = {};

  write("\n--- Speaker Resolution ---");
  write("Recommendations are advisory; choose explicitly or keep a temporary identity.\n");

  try {
    for (const recommendation of recommendations) {
      printSpeakerSamples(write, recommendation.label, samples);
      if (recommendation.category === "ambiguous-existing") {
        write("Ambiguous existing speaker:");
        if (recommendation.candidates.length === 0) {
          write("  No enrolled candidate cleared the acoustic floor.");
        } else {
          recommendation.candidates.forEach((candidate, index) => {
            write(
              `  ${index + 1}) ${candidate.name} (${Math.round(candidate.confidence * 100)}%) — ${candidate.evidence}`,
            );
          });
        }
        write("  r) reject all candidates (keep temporary identity)");
        write("  n) enter a new confirmed name");
        const reply = (await ask("Choose a candidate, r, or n: ")).trim();
        const index = Number.parseInt(reply, 10) - 1;
        if (index >= 0 && index < recommendation.candidates.length) {
          const selected = recommendation.candidates[index];
          names[recommendation.label] = selected.name;
          // A selected existing candidate is an explicit correction. The
          // orchestrator adds this run's clip only when enough speech exists.
          learn[recommendation.label] = selected.name;
        } else if (reply.toLowerCase() === "n") {
          const name = (await ask("Enter the new speaker name (or press Enter to keep temporary): ")).trim();
          if (name) {
            names[recommendation.label] = name;
            enroll[recommendation.label] = name;
          }
        }
      } else {
        write("New/unrecognized speaker: the transcript will keep a temporary identity unless you confirm a name.");
        if (recommendation.proposedName) {
          const confidence = recommendation.confidence === undefined
            ? ""
            : ` (${Math.round(recommendation.confidence * 100)}%)`;
          write(`  Suggested from self-introduction: ${recommendation.proposedName}${confidence}`);
          if (recommendation.evidence) write(`  Evidence: ${recommendation.evidence}`);
          write("  y) accept suggestion and enroll");
          write("  n) enter a different confirmed name");
          write("  r) reject (keep temporary identity)");
          const reply = (await ask("Choose y, n, or r: ")).trim().toLowerCase();
          if (reply === "y") {
            names[recommendation.label] = recommendation.proposedName;
            enroll[recommendation.label] = recommendation.proposedName;
          } else if (reply === "n") {
            const name = (await ask("Enter the confirmed speaker name (or press Enter to keep temporary): ")).trim();
            if (name) {
              names[recommendation.label] = name;
              enroll[recommendation.label] = name;
            }
          }
        } else {
          const name = (await ask("Enter a confirmed name (or press Enter to keep temporary): ")).trim();
          if (name) {
            names[recommendation.label] = name;
            enroll[recommendation.label] = name;
          }
        }
      }
      write("");
    }
  } finally {
    rl?.close();
  }

  write("--- Speaker resolution complete ---\n");
  return { names, enroll, learn };
}

export async function promptForSpeakerNames(
  segments: TranscriptSegment[],
  unmatchedSpeakers: string[],
  tentative: Record<string, TentativeMatch> = {},
  recommendations?: SpeakerResolutionRecommendation[],
  options?: SpeakerPromptOptions,
): Promise<PromptResult> {
  if (recommendations) {
    return promptForSpeakerResolutions(segments, recommendations, options);
  }
  // Gather sample utterances per speaker. Tentative-band labels are not in
  // unmatchedSpeakers (they have a candidate name), so include them too so
  // the user has context when confirming.
  const allLabels = [
    ...Object.keys(tentative),
    ...unmatchedSpeakers.filter((s) => !tentative[s]),
  ];
  const samples: Record<string, string[]> = {};
  for (const seg of segments) {
    if (!seg.speaker || !allLabels.includes(seg.speaker)) continue;
    if (!samples[seg.speaker]) samples[seg.speaker] = [];
    if (samples[seg.speaker].length < 3) {
      samples[seg.speaker].push(seg.text);
    }
  }

  const rl = createInterface({
    input: process.stdin,
    output: process.stderr,
  });

  const names: Record<string, string> = {};
  const enroll: Record<string, string> = {};

  const ask = (question: string): Promise<string> =>
    new Promise((resolve) => rl.question(question, resolve));

  console.error("\n--- Speaker Identification ---");

  // Confirmation pass: ask y/n/new for each tentative match first so the
  // user can dispatch quick yes-confirmations before the open-ended prompts.
  const tentativeLabels = Object.keys(tentative);
  if (tentativeLabels.length > 0) {
    console.error("Confirm tentative matches (y / n / new name).\n");
    for (const speaker of tentativeLabels) {
      const { name: candidate, confidence } = tentative[speaker];
      const speakerSamples = samples[speaker] ?? [];
      console.error(`${speaker} said:`);
      for (const sample of speakerSamples) {
        console.error(`  "${sample}"`);
      }

      const pct = Math.round(confidence * 100);
      const reply = (
        await ask(`Is ${speaker} = ${candidate} (confidence ${pct}%)? [y/n/new name] `)
      ).trim();

      if (reply.toLowerCase() === "y") {
        // Confirmed existing profile — assign name without re-enrollment.
        names[speaker] = candidate;
      } else if (reply.toLowerCase() === "n" || reply === "") {
        // Reject the tentative match; fall through to fresh-unknown prompt
        // below by leaving this label unnamed for now.
        if (!unmatchedSpeakers.includes(speaker)) {
          unmatchedSpeakers = [...unmatchedSpeakers, speaker];
        }
      } else {
        // Anything else is treated as a brand-new name.
        names[speaker] = reply;
        enroll[speaker] = reply;
      }
      console.error("");
    }
  }

  if (unmatchedSpeakers.length > 0) {
    console.error("Name each speaker below (press Enter to skip).\n");
  }

  for (const speaker of unmatchedSpeakers) {
    if (names[speaker]) continue; // already resolved via tentative pass
    const speakerSamples = samples[speaker] ?? [];
    console.error(`${speaker} said:`);
    for (const sample of speakerSamples) {
      console.error(`  "${sample}"`);
    }

    const name = (await ask(`Who is ${speaker}? `)).trim();

    if (name) {
      names[speaker] = name;
      enroll[speaker] = name;
    }
    console.error("");
  }

  rl.close();
  console.error("--- Saved! Future meetings will auto-identify these speakers. ---\n");

  return { names, enroll, learn: {} };
}

/**
 * Re-key per-speaker clips through the same rename the segments get.
 *
 * The clip map and the segments must agree on labels: a later chip rename or
 * `accept-suggestion` looks a clip up under the label the *segments* carry,
 * and a clip stranded under the raw diarized label reads as "audio missing"
 * (2026-08-04: auto-identify renamed Speaker 1 → a person at run time, the
 * clip stayed keyed "Speaker 1", and the owner's rename-then-enroll on that
 * record failed for a clip that was sitting right there).
 */
export function applyClipNames<T>(
  clips: Record<string, T>,
  nameMap: Record<string, string>,
  labelMap: Record<string, string> = {},
): Record<string, T> {
  const renamed: Record<string, T> = {};
  for (const [label, clip] of Object.entries(clips)) {
    const canonical = labelMap[label] ?? label;
    renamed[nameMap[canonical] ?? canonical] = clip;
  }
  return renamed;
}

export function applySpeakerNames(
  segments: TranscriptSegment[],
  nameMap: Record<string, string>,
  labelMap: Record<string, string> = {},
): TranscriptSegment[] {
  return segments.map((seg) => {
    if (!seg.speaker) return seg;
    // Rewrite sibling labels to their canonical first so a name resolved
    // against the canonical applies to every clustered sibling segment.
    const canonical = labelMap[seg.speaker] ?? seg.speaker;
    const resolved = nameMap[canonical] ?? canonical;
    return { ...seg, speaker: resolved };
  });
}
