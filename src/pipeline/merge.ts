import type { TranscriptionResult, TranscriptSegment } from "./transcribe.js";
import { SEGMENT_DURATION } from "../constants.js";

export function mergeTranscriptions(
  transcriptions: TranscriptionResult[],
  overlapSeconds: number
): TranscriptionResult {
  if (transcriptions.length === 1) {
    return transcriptions[0];
  }

  const merged: TranscriptSegment[] = [];
  let timeOffset = 0;

  for (let i = 0; i < transcriptions.length; i++) {
    const { segments } = transcriptions[i];

    if (i === 0) {
      // First chunk: take all segments
      merged.push(...segments);
      timeOffset = SEGMENT_DURATION;
    } else {
      // Subsequent chunks: skip overlap region, offset timestamps
      const nonOverlap = segments.filter((seg) => seg.start >= overlapSeconds);
      for (const seg of nonOverlap) {
        merged.push({
          start: seg.start - overlapSeconds + timeOffset,
          end: seg.end - overlapSeconds + timeOffset,
          text: seg.text,
        });
      }
      timeOffset += SEGMENT_DURATION;
    }
  }

  const text = merged.map((s) => s.text).join(" ");
  return { segments: merged, text };
}
