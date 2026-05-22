import { describe, it, expect } from "vitest";
import {
  buildSummaryPrompt,
  buildSpeakerLabeledTranscript,
  parseSummaryResponse,
} from "../../src/pipeline/summarize.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";

describe("buildSummaryPrompt", () => {
  it("includes the transcript in the prompt", () => {
    const prompt = buildSummaryPrompt("Hello, this is a test meeting.");
    expect(prompt).toContain("Hello, this is a test meeting.");
    expect(prompt).toContain("Key Topics");
    expect(prompt).toContain("Action Items");
    expect(prompt).toContain("Decisions Made");
  });

  it("asks for a title and tags", () => {
    const prompt = buildSummaryPrompt("Some transcript.");
    expect(prompt).toContain("### Title");
    expect(prompt).toContain("### Tags");
  });
});

describe("parseSummaryResponse", () => {
  it("extracts title and tags alongside the other sections", () => {
    const response = `### Title
Q3 Planning Sync

### Summary
We aligned on the roadmap.

### Key Topics
- **Roadmap** — Q3 priorities

### Decisions Made
- Ship feature X first

### Action Items
- [ ] Draft spec — assigned to Alice

### Tags
planning, roadmap, hiring`;

    const result = parseSummaryResponse(response);
    expect(result.title).toBe("Q3 Planning Sync");
    expect(result.tags).toEqual(["planning", "roadmap", "hiring"]);
    expect(result.narrative).toBe("We aligned on the roadmap.");
    expect(result.keyTopics).toEqual(["**Roadmap** — Q3 priorities"]);
  });

  it("strips wrapping quotes from the title and lowercases/dedupes tags", () => {
    const response = `### Title
"Kickoff Meeting"

### Summary
Intro.

### Tags
- Kickoff
- Planning
- planning`;

    const result = parseSummaryResponse(response);
    expect(result.title).toBe("Kickoff Meeting");
    expect(result.tags).toEqual(["kickoff", "planning"]);
  });

  it("defaults title to empty and tags to [] when absent", () => {
    const response = `### Summary
Just a summary, no title.`;
    const result = parseSummaryResponse(response);
    expect(result.title).toBe("");
    expect(result.tags).toEqual([]);
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
