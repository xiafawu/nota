import { describe, it, expect } from "vitest";
import { alignSpeakers, humanizeSpeaker } from "../../src/pipeline/diarize.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";
import type { DiarizationSegment } from "../../src/pipeline/diarize.js";

describe("humanizeSpeaker", () => {
  it("converts SPEAKER_00 to Speaker 1", () => {
    expect(humanizeSpeaker("SPEAKER_00")).toBe("Speaker 1");
  });

  it("converts SPEAKER_02 to Speaker 3", () => {
    expect(humanizeSpeaker("SPEAKER_02")).toBe("Speaker 3");
  });

  it("returns unknown speakers as-is", () => {
    expect(humanizeSpeaker("UNKNOWN")).toBe("UNKNOWN");
  });
});

describe("alignSpeakers", () => {
  it("assigns speaker to segment with maximum overlap", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello" },
      { start: 5, end: 10, text: "World" },
    ];
    const diarization: DiarizationSegment[] = [
      { start: 0, end: 6, speaker: "SPEAKER_00" },
      { start: 6, end: 10, speaker: "SPEAKER_01" },
    ];
    const result = alignSpeakers(segments, diarization);
    expect(result[0].speaker).toBe("Speaker 1");
    expect(result[1].speaker).toBe("Speaker 2");
  });

  it("leaves speaker undefined when no diarization overlaps", () => {
    const segments: TranscriptSegment[] = [
      { start: 100, end: 110, text: "Late segment" },
    ];
    const diarization: DiarizationSegment[] = [
      { start: 0, end: 5, speaker: "SPEAKER_00" },
    ];
    const result = alignSpeakers(segments, diarization);
    expect(result[0].speaker).toBeUndefined();
  });

  it("handles empty diarization array", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello" },
    ];
    const result = alignSpeakers(segments, []);
    expect(result[0].speaker).toBeUndefined();
  });
});
