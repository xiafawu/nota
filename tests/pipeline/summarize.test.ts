import { describe, it, expect } from "vitest";
import { buildSummaryPrompt, buildSpeakerLabeledTranscript } from "../../src/pipeline/summarize.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";

describe("buildSummaryPrompt", () => {
  it("includes the transcript in the prompt", () => {
    const prompt = buildSummaryPrompt("Hello, this is a test meeting.");
    expect(prompt).toContain("Hello, this is a test meeting.");
    expect(prompt).toContain("Key Topics");
    expect(prompt).toContain("Action Items");
    expect(prompt).toContain("Decisions Made");
  });
});

describe("buildSpeakerLabeledTranscript", () => {
  it("formats segments with speaker labels", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello", speaker: "Speaker 1" },
      { start: 5, end: 10, text: "Hi there", speaker: "Speaker 2" },
      { start: 10, end: 15, text: "Let's start" },
    ];
    const result = buildSpeakerLabeledTranscript(segments);
    expect(result).toContain("Speaker 1: Hello");
    expect(result).toContain("Speaker 2: Hi there");
    expect(result).toContain("Let's start");
    expect(result).not.toContain("undefined");
  });
});
