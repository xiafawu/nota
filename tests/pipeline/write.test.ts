import { describe, it, expect } from "vitest";
import { buildMarkdown } from "../../src/pipeline/write.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";
import type { MeetingSummary } from "../../src/pipeline/summarize.js";

describe("buildMarkdown", () => {
  it("produces valid markdown with all sections", () => {
    const summary: MeetingSummary = {
      narrative: "A productive meeting.",
      keyTopics: ["**API design** — discussed endpoints"],
      decisions: ["Use REST over GraphQL"],
      actionItems: ["[ ] Write API spec — assigned to Alice"],
    };
    const segments: TranscriptSegment[] = [
      { start: 0, end: 10, text: "Hello everyone" },
      { start: 10, end: 20, text: "Let's discuss the API" },
    ];
    const md = buildMarkdown({
      summary,
      segments,
      date: "2026-03-10",
      duration: 47,
      source: "standup.mp3",
    });

    expect(md).toContain("# Meeting Summary");
    expect(md).toContain("**Date:** 2026-03-10");
    expect(md).toContain("**Duration:** 47 minutes");
    expect(md).toContain("A productive meeting.");
    expect(md).toContain("[00:00]");
    expect(md).toContain("Hello everyone");
    expect(md).toContain("## Full Transcript");
  });

  it("includes speaker labels in transcript when present", () => {
    const summary: MeetingSummary = {
      narrative: "A productive meeting.",
      keyTopics: ["**Budget** — discussed allocations"],
      decisions: ["Increase Q3 budget"],
      actionItems: ["[ ] Submit report — assigned to Speaker 1"],
    };
    const segments: TranscriptSegment[] = [
      { start: 0, end: 10, text: "Hello everyone", speaker: "Speaker 1" },
      { start: 10, end: 20, text: "Let's begin", speaker: "Speaker 2" },
      { start: 20, end: 30, text: "Sounds good" },  // no speaker
    ];
    const md = buildMarkdown({
      summary,
      segments,
      date: "2026-03-10",
      duration: 30,
      source: "meeting.mp3",
    });

    expect(md).toContain("[00:00] **Speaker 1:** Hello everyone");
    expect(md).toContain("[00:10] **Speaker 2:** Let's begin");
    expect(md).toContain("[00:20] Sounds good");
  });
});
