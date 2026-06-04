import { EagleProfiler, Eagle } from "@picovoice/eagle-node";
import { frames } from "../utils/pcm.js";

/** Auto-assign a name at/above this Eagle score; prompt in the band below. */
export const MATCH_THRESHOLD = 0.6;
export const TENTATIVE_THRESHOLD = 0.4;

export class InsufficientSpeechError extends Error {
  constructor() {
    super("Not enough speech to enroll a voice profile");
    this.name = "InsufficientSpeechError";
  }
}

export function isEagleAvailable(accessKey?: string): boolean {
  return Boolean(accessKey && accessKey.trim());
}

/**
 * Build an Eagle speaker profile from a speaker's PCM. Feeds frame-sized
 * windows until enrollment reaches 100%, then flush + export. Throws
 * InsufficientSpeechError if 100% is never reached (too little clean speech).
 */
export async function enrollProfile(
  accessKey: string,
  pcm: Int16Array,
): Promise<Uint8Array> {
  const profiler = new EagleProfiler(accessKey);
  try {
    let percent = 0;
    for (const frame of frames(pcm, profiler.frameLength)) {
      percent = profiler.enroll(frame);
      if (percent >= 100) break;
    }
    if (percent < 100) percent = profiler.flush();
    if (percent < 100) throw new InsufficientSpeechError();
    return profiler.export();
  } finally {
    profiler.release();
  }
}

/**
 * Score each label's PCM against a flat list of enrolled profiles. Feeds
 * chunks of >= minProcessSamples and means the per-profile scores, then
 * returns the best { index, score } per label. `index` points into `profiles`.
 * Labels with too little voiced audio to score are omitted.
 */
export function recognize(
  accessKey: string,
  pcmByLabel: Record<string, Int16Array>,
  profiles: Uint8Array[],
): Record<string, { index: number; score: number }> {
  const out: Record<string, { index: number; score: number }> = {};
  if (profiles.length === 0) return out;
  const eagle = new Eagle(accessKey);
  try {
    const chunk = eagle.minProcessSamples;
    for (const [label, pcm] of Object.entries(pcmByLabel)) {
      const sums = new Array<number>(profiles.length).fill(0);
      let n = 0;
      for (let i = 0; i + chunk <= pcm.length; i += chunk) {
        const scores = eagle.process(pcm.subarray(i, i + chunk), profiles);
        if (!scores) continue;
        for (let p = 0; p < profiles.length; p++) sums[p] += scores[p];
        n++;
      }
      if (n === 0) continue;
      let bestIdx = 0;
      let best = -Infinity;
      for (let p = 0; p < profiles.length; p++) {
        const mean = sums[p] / n;
        if (mean > best) {
          best = mean;
          bestIdx = p;
        }
      }
      out[label] = { index: bestIdx, score: best };
    }
    return out;
  } finally {
    eagle.release();
  }
}
