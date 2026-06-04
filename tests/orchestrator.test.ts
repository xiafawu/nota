import { describe, it, expect } from "vitest";
import { runPipeline, selectClipRanges } from "../src/orchestrator.js";
import type { TranscriptSegment } from "../src/pipeline/transcribe.js";

describe("orchestrator", () => {
  it("exports runPipeline function", () => {
    expect(runPipeline).toBeDefined();
    expect(typeof runPipeline).toBe("function");
  });
});

describe("selectClipRanges", () => {
  const segs: TranscriptSegment[] = [
    { start: 0, end: 2, text: "", speaker: "Speaker 1" },
    { start: 5, end: 15, text: "", speaker: "Speaker 1" },
    { start: 20, end: 22, text: "", speaker: "Speaker 1" },
    { start: 22, end: 30, text: "", speaker: "Speaker 2" },
  ];

  it("picks the longest utterances first up to the target seconds", () => {
    // The 10s utterance (5–15) alone meets a 10s target → stop there.
    expect(selectClipRanges(segs, "Speaker 1", 10)).toEqual([{ start: 5, end: 15 }]);
  });

  it("accumulates multiple utterances when one is not enough", () => {
    // target 11s: 10s utterance, then the next-longest (2s) to cross 11.
    const ranges = selectClipRanges(segs, "Speaker 1", 11);
    expect(ranges[0]).toEqual({ start: 5, end: 15 });
    expect(ranges).toHaveLength(2);
  });

  it("only includes the requested speaker", () => {
    const ranges = selectClipRanges(segs, "Speaker 2", 100);
    expect(ranges).toEqual([{ start: 22, end: 30 }]);
  });

  it("returns empty for an unknown speaker", () => {
    expect(selectClipRanges(segs, "Speaker 9", 10)).toEqual([]);
  });
});
