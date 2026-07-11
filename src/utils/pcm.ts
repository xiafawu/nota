import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** Eagle operates on 16 kHz, mono, 16-bit signed little-endian PCM. */
export const SAMPLE_RATE = 16000;

/**
 * Decode any ffmpeg-readable audio file to a mono 16 kHz Int16Array.
 * Streams raw `s16le` on stdout so we never write a temp WAV. The buffer is
 * copied into a fresh, offset-0 Int16Array so callers can subarray it freely.
 */
export async function decodePcm(inputPath: string): Promise<Int16Array> {
  const { stdout } = await execFileAsync(
    "ffmpeg",
    [
      "-v", "quiet",
      "-i", inputPath,
      "-f", "s16le",
      "-acodec", "pcm_s16le",
      "-ar", String(SAMPLE_RATE),
      "-ac", "1",
      "-",
    ],
    { encoding: "buffer", maxBuffer: 1024 * 1024 * 512 },
  );
  const buf = stdout as unknown as Buffer;
  const samples = Math.floor(buf.length / 2);
  const out = new Int16Array(samples);
  for (let i = 0; i < samples; i++) {
    out[i] = buf.readInt16LE(i * 2);
  }
  return out;
}

export interface TimeRange {
  start: number;
  end: number;
}

/** Concatenate the PCM sample windows covered by the given time ranges. */
export function slicePcm(pcm: Int16Array, ranges: TimeRange[]): Int16Array {
  const parts: Int16Array[] = [];
  let total = 0;
  for (const { start, end } of ranges) {
    const s = Math.max(0, Math.floor(start * SAMPLE_RATE));
    const e = Math.min(pcm.length, Math.floor(end * SAMPLE_RATE));
    if (e > s) {
      const part = pcm.subarray(s, e);
      parts.push(part);
      total += part.length;
    }
  }
  const out = new Int16Array(total);
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

/** Concatenate chunks and trim to `seconds` (or return all if shorter). */
export function concatToSeconds(chunks: Int16Array[], seconds: number): Int16Array {
  const target = Math.floor(seconds * SAMPLE_RATE);
  const out = new Int16Array(target);
  let off = 0;
  for (const c of chunks) {
    if (off >= target) break;
    const take = Math.min(c.length, target - off);
    out.set(c.subarray(0, take), off);
    off += take;
  }
  return off === target ? out : out.subarray(0, off);
}

/** Yield fixed-size frames (drops a trailing partial frame). */
export function* frames(pcm: Int16Array, frameLength: number): Generator<Int16Array> {
  for (let i = 0; i + frameLength <= pcm.length; i += frameLength) {
    yield pcm.subarray(i, i + frameLength);
  }
}
