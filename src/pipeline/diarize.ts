import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { TranscriptSegment } from "./transcribe.js";

const execFileAsync = promisify(execFile);

export interface DiarizationSegment {
  start: number;
  end: number;
  speaker: string;
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SCRIPT_PATH = path.resolve(__dirname, "../../scripts/diarize.py");

export async function runDiarization(
  audioPath: string
): Promise<DiarizationSegment[]> {
  const { stdout, stderr } = await execFileAsync("python3", [
    SCRIPT_PATH,
    audioPath,
  ], { maxBuffer: 50 * 1024 * 1024 });

  if (!stdout.trim()) {
    throw new Error(
      `Diarization produced no output${stderr ? `: ${stderr}` : ""}`
    );
  }

  const segments: DiarizationSegment[] = JSON.parse(stdout);
  return segments;
}

export function humanizeSpeaker(speaker: string): string {
  const match = speaker.match(/^SPEAKER_(\d+)$/);
  if (!match) return speaker;
  return `Speaker ${parseInt(match[1], 10) + 1}`;
}

function computeOverlap(
  a: { start: number; end: number },
  b: { start: number; end: number }
): number {
  const start = Math.max(a.start, b.start);
  const end = Math.min(a.end, b.end);
  return Math.max(0, end - start);
}

export function alignSpeakers(
  segments: TranscriptSegment[],
  diarization: DiarizationSegment[]
): TranscriptSegment[] {
  return segments.map((seg) => {
    let bestSpeaker: string | undefined;
    let bestOverlap = 0;

    for (const dia of diarization) {
      const overlap = computeOverlap(seg, dia);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestSpeaker = dia.speaker;
      }
    }

    return {
      ...seg,
      speaker: bestSpeaker ? humanizeSpeaker(bestSpeaker) : undefined,
    };
  });
}
