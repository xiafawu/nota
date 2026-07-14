import { readFile, writeFile, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import type { TranscriptSegment } from "./transcribe.js";
import { cosine, MATCH_THRESHOLD, TENTATIVE_THRESHOLD } from "./embed.js";

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
}

export interface SpeakerProfile {
  voiceprints: Voiceprint[];
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
    speakers[name] = { voiceprints: vps };
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
 * Assign enrolled names to diarized labels from a per-label score vector.
 * `scoredByLabel[label][i]` is the cosine score of `label` against the
 * i-th enrolled voiceprint; `names[i]` is the speaker name that voiceprint
 * belongs to. Greedy global assignment: sort every (label, voiceprint)
 * candidate at/above the tentative floor by score, then claim each label and
 * each name at most once. A claim at/above MATCH_THRESHOLD is confident; in
 * `[TENTATIVE_THRESHOLD, MATCH_THRESHOLD)` it is tentative (caller confirms).
 */
export function rankMatches(
  scoredByLabel: Record<string, number[]>,
  names: string[],
): Record<string, MatchResult> {
  const candidates: { label: string; name: string; score: number }[] = [];
  for (const [label, scores] of Object.entries(scoredByLabel)) {
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
}

export async function promptForSpeakerNames(
  segments: TranscriptSegment[],
  unmatchedSpeakers: string[],
  tentative: Record<string, TentativeMatch> = {},
): Promise<PromptResult> {
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

  return { names, enroll };
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
