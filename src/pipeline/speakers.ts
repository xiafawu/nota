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

const SPEAKERS_DIR = path.join(homedir(), ".meetingsum");
const SPEAKERS_FILE = path.join(SPEAKERS_DIR, "speakers.json");
const SIMILARITY_THRESHOLD = 0.70;

const QTA_EXTENSIONS = new Set([".qta"]);

export interface SpeakerProfile {
  embedding: number[];
  enrolledAt: string;
  source: string;
}

export interface SpeakerStore {
  version: number;
  speakers: Record<string, SpeakerProfile>;
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

export async function loadProfiles(): Promise<SpeakerStore> {
  try {
    const data = await readFile(SPEAKERS_FILE, "utf-8");
    return JSON.parse(data);
  } catch {
    return { version: 1, speakers: {} };
  }
}

export async function saveProfiles(store: SpeakerStore): Promise<void> {
  await mkdir(SPEAKERS_DIR, { recursive: true });
  await writeFile(SPEAKERS_FILE, JSON.stringify(store, null, 2), "utf-8");
}

export function matchSpeakers(
  embeddings: Record<string, number[]>,
  profiles: SpeakerStore
): Record<string, { name: string; confidence: number }> {
  const matches: Record<string, { name: string; confidence: number }> = {};
  const profileEntries = Object.entries(profiles.speakers);

  if (profileEntries.length === 0) return matches;

  // Track which profile names have been claimed to avoid duplicates
  const claimed = new Set<string>();

  // Sort by best match first so higher-confidence matches claim names first
  const candidates: { label: string; name: string; score: number }[] = [];
  for (const [label, embedding] of Object.entries(embeddings)) {
    for (const [name, profile] of profileEntries) {
      const score = cosineSimilarity(embedding, profile.embedding);
      if (score >= SIMILARITY_THRESHOLD) {
        candidates.push({ label, name, score });
      }
    }
  }
  candidates.sort((a, b) => b.score - a.score);

  for (const { label, name, score } of candidates) {
    if (matches[label] || claimed.has(name)) continue;
    matches[label] = { name, confidence: score };
    claimed.add(name);
  }

  return matches;
}

async function convertForEmbedding(inputPath: string): Promise<string | null> {
  const ext = path.extname(inputPath).toLowerCase();
  if (!QTA_EXTENSIONS.has(ext)) return null;

  const tmpPath = path.join(
    tmpdir(),
    `meetingsum-emb-${Date.now()}${Math.random().toString(36).slice(2)}.wav`
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

export async function promptForSpeakerNames(
  segments: TranscriptSegment[],
  unmatchedSpeakers: string[]
): Promise<Record<string, string>> {
  // Gather sample utterances per speaker
  const samples: Record<string, string[]> = {};
  for (const seg of segments) {
    if (!seg.speaker || !unmatchedSpeakers.includes(seg.speaker)) continue;
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

  console.error("\n--- Speaker Identification ---");
  console.error("Name each speaker below (press Enter to skip).\n");

  for (const speaker of unmatchedSpeakers) {
    const speakerSamples = samples[speaker] ?? [];
    console.error(`${speaker} said:`);
    for (const sample of speakerSamples) {
      console.error(`  "${sample}"`);
    }

    const name = await new Promise<string>((resolve) => {
      rl.question(`Who is ${speaker}? `, resolve);
    });

    if (name.trim()) {
      names[speaker] = name.trim();
    }
    console.error("");
  }

  rl.close();
  console.error("--- Saved! Future meetings will auto-identify these speakers. ---\n");

  return names;
}

export function applySpeakerNames(
  segments: TranscriptSegment[],
  nameMap: Record<string, string>
): TranscriptSegment[] {
  return segments.map((seg) => ({
    ...seg,
    speaker:
      seg.speaker && nameMap[seg.speaker]
        ? nameMap[seg.speaker]
        : seg.speaker,
  }));
}
