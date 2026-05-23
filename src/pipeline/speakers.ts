import { readFile, writeFile, mkdir, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { tmpdir } from "node:os";
import path from "node:path";
import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import type { TranscriptSegment } from "./transcribe.js";

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SCRIPT_PATH = path.resolve(__dirname, "../../scripts/embeddings.py");
const PYTHON_BIN = process.env.PYTHON_BIN ?? "python3";

const SPEAKERS_DIR = path.join(homedir(), ".nota");
const LEGACY_SPEAKERS_FILE = path.join(homedir(), ".meetingsum", "speakers.json");
const SPEAKERS_FILE = path.join(SPEAKERS_DIR, "speakers.json");
// >= SIMILARITY_THRESHOLD auto-claims silently. >= LOW_CONFIDENCE but below
// SIMILARITY_THRESHOLD enters the confirmation band: prompt the user with
// the candidate and a confidence pct so cross-session drift doesn't silently
// mis-attribute speech. Below LOW_CONFIDENCE falls through to fresh-unknown.
const SIMILARITY_THRESHOLD = 0.70;
export const LOW_CONFIDENCE = 0.55;
// Diarizers occasionally split one real speaker into multiple labels with
// near-identical voiceprints; collapse pairs at or above this cosine before
// matching so we don't enroll the same person twice.
export const MERGE_THRESHOLD = 0.85;

export type MatchResult = { name: string; confidence: number; tentative?: boolean };

export const DEFAULT_SPEAKERS_FILE = SPEAKERS_FILE;
export const DEFAULT_LEGACY_SPEAKERS_FILE = LEGACY_SPEAKERS_FILE;

const QTA_EXTENSIONS = new Set([".qta"]);

// Schema v2: a profile is a *pointer* — one name maps to N voiceprints
// (one per enrollment event). Match scores a new cluster against every
// voiceprint under each name and takes the max, so adding voiceprints can
// only help recall (no centroid averaging, no drift compounding). Schema
// v1 (single top-level embedding) is migrated in `loadProfiles`.
export interface Voiceprint {
  /** ISO timestamp of enrollment — also serves as stable CLI handle. */
  id: string;
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

// Internal types only used during migration from v1 on-disk format.
interface LegacySpeakerProfile {
  embedding: number[];
  enrolledAt: string;
  source: string;
}
interface LegacySpeakerStore {
  version?: number;
  speakers: Record<string, LegacySpeakerProfile | SpeakerProfile>;
}

const STORE_VERSION = 2;

function isLegacyProfile(
  profile: LegacySpeakerProfile | SpeakerProfile,
): profile is LegacySpeakerProfile {
  return (
    Array.isArray((profile as LegacySpeakerProfile).embedding) &&
    !Array.isArray((profile as SpeakerProfile).voiceprints)
  );
}

/**
 * Promote a v1 single-embedding profile into a v2 voiceprints array. The
 * single legacy embedding becomes voiceprint #1 with id = enrolledAt; the
 * profile remains addressable by the same name (callers see only the v2
 * shape after `loadProfiles`).
 */
function migrateProfile(
  profile: LegacySpeakerProfile | SpeakerProfile,
): SpeakerProfile {
  if (!isLegacyProfile(profile)) return profile;
  return {
    voiceprints: [
      {
        id: profile.enrolledAt,
        embedding: profile.embedding,
        enrolledAt: profile.enrolledAt,
        source: profile.source,
      },
    ],
  };
}

function migrateStore(raw: LegacySpeakerStore): SpeakerStore {
  const speakers: Record<string, SpeakerProfile> = {};
  for (const [name, profile] of Object.entries(raw.speakers ?? {})) {
    speakers[name] = migrateProfile(profile);
  }
  return { version: STORE_VERSION, speakers };
}

export function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  const denom = Math.sqrt(normA) * Math.sqrt(normB);
  return denom === 0 ? 0 : dot / denom;
}

export async function loadProfiles(
  filePath: string = SPEAKERS_FILE,
): Promise<SpeakerStore> {
  // Always returns the v2 shape; v1 stores are migrated in-memory and
  // re-serialized as v2 on next `saveProfiles`. We never persist a hybrid.
  try {
    const data = await readFile(filePath, "utf-8");
    return migrateStore(JSON.parse(data) as LegacySpeakerStore);
  } catch {
    if (filePath === SPEAKERS_FILE) {
      try {
        const legacyData = await readFile(LEGACY_SPEAKERS_FILE, "utf-8");
        return migrateStore(JSON.parse(legacyData) as LegacySpeakerStore);
      } catch {
        return { version: STORE_VERSION, speakers: {} };
      }
    }
    return { version: STORE_VERSION, speakers: {} };
  }
}

export async function saveProfiles(
  store: SpeakerStore,
  filePath: string = SPEAKERS_FILE,
): Promise<void> {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, JSON.stringify(store, null, 2), "utf-8");
}

/**
 * Cluster diarizer labels whose embeddings are near-duplicates so a single
 * real speaker is not enrolled twice. Uses single-linkage agglomerative
 * clustering on pairwise cosine: any pair >= `threshold` joins clusters,
 * which means transitive chains (A~B, B~C) collapse even if A~C is below
 * threshold. Earliest label in iteration order becomes the cluster's canonical
 * id; the canonical embedding is the mean of cluster members,
 * L2-renormalized so cosine comparisons against profiles stay well-scaled.
 */
export function clusterLabels(
  embeddings: Record<string, number[]>,
  threshold: number = MERGE_THRESHOLD
): {
  canonicalOf: Record<string, string>;
  merged: Record<string, number[]>;
} {
  const labels = Object.keys(embeddings);
  const canonicalOf: Record<string, string> = {};
  const merged: Record<string, number[]> = {};

  if (labels.length === 0) return { canonicalOf, merged };

  // Union-find over label indices keeps single-linkage transitive merging
  // simple without recursive set operations.
  const parent = labels.map((_, i) => i);
  const find = (i: number): number => {
    while (parent[i] !== i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  };
  const union = (i: number, j: number) => {
    const ri = find(i);
    const rj = find(j);
    if (ri === rj) return;
    // Keep the earlier index as the root so canonical = earliest occurrence.
    if (ri < rj) parent[rj] = ri;
    else parent[ri] = rj;
  };

  for (let i = 0; i < labels.length; i++) {
    for (let j = i + 1; j < labels.length; j++) {
      const sim = cosineSimilarity(embeddings[labels[i]], embeddings[labels[j]]);
      if (sim >= threshold) union(i, j);
    }
  }

  // Group label indices by cluster root.
  const groups: Record<number, number[]> = {};
  for (let i = 0; i < labels.length; i++) {
    const root = find(i);
    if (!groups[root]) groups[root] = [];
    groups[root].push(i);
  }

  for (const rootKey of Object.keys(groups)) {
    const indices = groups[Number(rootKey)];
    // Earliest label by original iteration order is the canonical id.
    indices.sort((a, b) => a - b);
    const canonical = labels[indices[0]];

    // Average member embeddings dimension-wise.
    const dim = embeddings[canonical].length;
    const mean = new Array<number>(dim).fill(0);
    for (const idx of indices) {
      const vec = embeddings[labels[idx]];
      for (let d = 0; d < dim; d++) mean[d] += vec[d];
    }
    for (let d = 0; d < dim; d++) mean[d] /= indices.length;

    // L2-renormalize so subsequent cosine comparisons are not biased by
    // averaging-induced shrinkage. Zero-norm vectors are passed through
    // unchanged (cosineSimilarity already handles them safely).
    let norm = 0;
    for (let d = 0; d < dim; d++) norm += mean[d] * mean[d];
    norm = Math.sqrt(norm);
    if (norm > 0) {
      for (let d = 0; d < dim; d++) mean[d] /= norm;
    }

    merged[canonical] = mean;
    for (const idx of indices) {
      canonicalOf[labels[idx]] = canonical;
    }
  }

  return { canonicalOf, merged };
}

export function matchSpeakers(
  embeddings: Record<string, number[]>,
  profiles: SpeakerStore
): Record<string, MatchResult> {
  const matches: Record<string, MatchResult> = {};
  const profileEntries = Object.entries(profiles.speakers);

  if (profileEntries.length === 0) return matches;

  // Collapse near-duplicate diarizer labels first so one real speaker can
  // only claim a profile name once.
  const { merged } = clusterLabels(embeddings, MERGE_THRESHOLD);

  // Track which profile names have been claimed to avoid duplicates
  const claimed = new Set<string>();

  // Sort by best match first so higher-confidence matches claim names first.
  // Anything in [LOW_CONFIDENCE, SIMILARITY_THRESHOLD) is tentative — still a
  // candidate, but routed through a confirmation prompt instead of silent
  // auto-claim.
  //
  // For each name, score = MAX cosine across that name's voiceprints. Max
  // (not mean) is the right aggregation for the pointer model: any one
  // voiceprint resembling the cluster centroid is enough evidence — a stale
  // voiceprint can't drag a fresh one's score down.
  const candidates: { label: string; name: string; score: number }[] = [];
  for (const [label, embedding] of Object.entries(merged)) {
    for (const [name, profile] of profileEntries) {
      if (profile.voiceprints.length === 0) continue;
      let best = -Infinity;
      for (const vp of profile.voiceprints) {
        const s = cosineSimilarity(embedding, vp.embedding);
        if (s > best) best = s;
      }
      if (best >= LOW_CONFIDENCE) {
        candidates.push({ label, name, score: best });
      }
    }
  }
  candidates.sort((a, b) => b.score - a.score);

  for (const { label, name, score } of candidates) {
    if (matches[label] || claimed.has(name)) continue;
    const tentative = score < SIMILARITY_THRESHOLD;
    matches[label] = tentative
      ? { name, confidence: score, tentative: true }
      : { name, confidence: score };
    claimed.add(name);
  }

  return matches;
}

async function convertForEmbedding(inputPath: string): Promise<string | null> {
  const ext = path.extname(inputPath).toLowerCase();
  if (!QTA_EXTENSIONS.has(ext)) return null;

  const tmpPath = path.join(
    tmpdir(),
    `nota-emb-${Date.now()}${Math.random().toString(36).slice(2)}.wav`
  );
  await execFileAsync("ffmpeg", [
    "-y", "-i", inputPath,
    "-ar", "16000", "-ac", "1",
    tmpPath,
  ]);
  return tmpPath;
}

export async function extractEmbeddings(
  audioPath: string,
  segments: TranscriptSegment[]
): Promise<Record<string, number[]>> {
  // Group segments by speaker
  const speakerSegments: Record<string, { start: number; end: number }[]> = {};
  for (const seg of segments) {
    if (!seg.speaker) continue;
    if (!speakerSegments[seg.speaker]) {
      speakerSegments[seg.speaker] = [];
    }
    speakerSegments[seg.speaker].push({ start: seg.start, end: seg.end });
  }

  // Convert .qta if needed
  const tmpFile = await convertForEmbedding(audioPath);
  const processPath = tmpFile ?? audioPath;

  try {
    const input = JSON.stringify({
      audio: processPath,
      speakers: speakerSegments,
    });

    const result = await new Promise<Record<string, number[]>>(
      (resolve, reject) => {
        const child = spawn(PYTHON_BIN, [SCRIPT_PATH], {
          stdio: ["pipe", "pipe", "pipe"],
        });

        let stdout = "";
        let stderr = "";

        child.stdout.on("data", (data: Buffer) => {
          stdout += data.toString();
        });
        child.stderr.on("data", (data: Buffer) => {
          stderr += data.toString();
        });

        child.on("close", (code) => {
          if (code !== 0) {
            reject(
              new Error(
                `Embedding extraction failed (exit ${code})${stderr ? `: ${stderr}` : ""}`
              )
            );
            return;
          }
          if (!stdout.trim()) {
            reject(
              new Error(
                `Embedding extraction produced no output${stderr ? `: ${stderr}` : ""}`
              )
            );
            return;
          }
          try {
            resolve(JSON.parse(stdout));
          } catch {
            reject(new Error(`Invalid embedding output: ${stdout.slice(0, 200)}`));
          }
        });

        child.stdin.write(input);
        child.stdin.end();
      }
    );

    return result;
  } finally {
    if (tmpFile) {
      await unlink(tmpFile).catch(() => {});
    }
  }
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
  tentative: Record<string, TentativeMatch> = {}
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
  labelMap: Record<string, string> = {}
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
