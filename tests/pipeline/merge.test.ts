import { describe, it, expect } from "vitest";
import { mergeTranscriptions } from "../../src/pipeline/merge.js";
import type { TranscriptionResult } from "../../src/pipeline/transcribe.js";

describe("mergeTranscriptions", () => {
  it("returns single transcription as-is", () => {
    const input: TranscriptionResult[] = [
      {
        segments: [{ start: 0, end: 10, text: "Hello world" }],
        text: "Hello world",
      },
    ];
    const result = mergeTranscriptions(input, 0);
    expect(result.segments).toHaveLength(1);
    expect(result.text).toBe("Hello world");
  });

  it("preserves extra properties on segments through merge", () => {
    const overlap = 30;
    const input: TranscriptionResult[] = [
      {
        segments: [
          { start: 0, end: 300, text: "First part", speaker: "Speaker 1" } as any,
        ],
        text: "First part",
      },
      {
        segments: [
          { start: 0, end: 30, text: "overlap" },
          { start: 30, end: 300, text: "Second part", speaker: "Speaker 2" } as any,
        ],
        text: "overlap Second part",
      },
    ];
    const result = mergeTranscriptions(input, overlap);
    expect((result.segments[0] as any).speaker).toBe("Speaker 1");
    expect((result.segments[1] as any).speaker).toBe("Speaker 2");
  });

  it("merges two transcriptions, drops overlap, and offsets timestamps", () => {
    const overlap = 30; // matches OVERLAP_DURATION
    const input: TranscriptionResult[] = [
      {
        segments: [
          { start: 0, end: 300, text: "First part" },
          { start: 300, end: 600, text: "End of first chunk" },
        ],
        text: "First part End of first chunk",
      },
      {
        segments: [
          { start: 0, end: 30, text: "End of first chunk" }, // overlap — should be dropped
          { start: 30, end: 300, text: "Second part" },
        ],
        text: "End of first chunk Second part",
      },
    ];
    const result = mergeTranscriptions(input, overlap);
    // First chunk: 2 segments, second chunk: 1 non-overlap segment = 3 total
    expect(result.segments).toHaveLength(3);
    // Second chunk's non-overlap segment should be offset by SEGMENT_DURATION (600)
    const lastSeg = result.segments[2];
    expect(lastSeg.start).toBe(600); // 30 - 30 + 600
    expect(lastSeg.text).toBe("Second part");
  });
});
