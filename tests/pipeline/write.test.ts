import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, it, expect } from "vitest";
import { buildMarkdown, writeOutputFromRecord } from "../../src/pipeline/write.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";
import type { MeetingSummary } from "../../src/pipeline/summarize.js";
import type { HistoryRecord } from "../../src/pipeline/history.js";

describe("buildMarkdown", () => {
  it("produces valid markdown with all sections", () => {
    const summary: MeetingSummary = {
      title: "API Design Standup",
      tags: ["api", "design", "rest"],
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
      capturedDate: "2026-03-08",
      transcribedDate: "2026-03-10",
      duration: 47,
      source: "standup.mp3",
    });

    expect(md).toContain("# API Design Standup");
    expect(md).toContain("**Tags:** api, design, rest");
    expect(md).toContain("**Captured:** 2026-03-08");
    expect(md).toContain("**Transcribed:** 2026-03-10");
    expect(md).toContain("**Duration:** 47 minutes");
    expect(md).toContain("A productive meeting.");
    expect(md).toContain("[00:00]");
    expect(md).toContain("Hello everyone");
    expect(md).toContain("## Full Transcript");
  });

  it("includes speaker labels in transcript when present", () => {
    const summary: MeetingSummary = {
      title: "Q3 Budget Review",
      tags: ["budget", "finance"],
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
      capturedDate: "2026-03-10",
      transcribedDate: "2026-03-10",
      duration: 30,
      source: "meeting.mp3",
    });

    expect(md).toContain("[00:00] **Speaker 1:** Hello everyone");
    expect(md).toContain("[00:10] **Speaker 2:** Let's begin");
    expect(md).toContain("[00:20] Sounds good");
  });

  it("renders an em dash when captured date is unknown", () => {
    const summary: MeetingSummary = {
      title: "Untitled",
      tags: [],
      narrative: "x",
      keyTopics: [],
      decisions: [],
      actionItems: [],
    };
    const md = buildMarkdown({
      summary,
      segments: [],
      capturedDate: null,
      transcribedDate: "2026-03-10",
      duration: 5,
      source: "a.mp3",
    });
    expect(md).toContain("**Captured:** —");
    expect(md).toContain("**Transcribed:** 2026-03-10");
  });

  it("renders transcript-only output when summary is omitted", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello world", speaker: "Speaker 1" },
    ];
    const md = buildMarkdown({
      segments,
      capturedDate: null,
      transcribedDate: "2026-07-15",
      duration: 3,
      source: "test.m4a",
    });
    expect(md).toContain("# Transcript");
    expect(md).not.toContain("## Summary");
    expect(md).not.toContain("## Key Topics");
    expect(md).not.toContain("## Decisions Made");
    expect(md).not.toContain("## Action Items");
    expect(md).toContain("## Full Transcript");
    expect(md).toContain("Hello world");
  });
});

describe("writeOutputFromRecord", () => {
  function makeRecord(overrides: Partial<HistoryRecord> = {}): HistoryRecord {
    return {
      id: "20260718-000000Z-abcd1234",
      createdAt: "2026-07-18T10:00:00.000Z",
      updatedAt: "2026-07-18T10:00:00.000Z",
      capturedAt: "2026-07-17T08:00:00.000Z",
      sourcePath: "/tmp/meeting.m4a",
      sourceName: "meeting.m4a",
      provider: "assemblyai",
      options: { diarize: true, identify: false, model: "gpt-4o" },
      durationMinutes: 12,
      transcriptText: "Hello world",
      segments: [{ start: 0, end: 1, text: "Hello world", speaker: "Speaker 1" }],
      summary: {
        title: "Rewritten Meeting",
        tags: ["rewrite"],
        narrative: "Rewritten from the record.",
        keyTopics: ["**Topic** — details"],
        decisions: [],
        actionItems: [],
      },
      status: "completed",
      ...overrides,
    };
  }

  it("renders the record to its outputPath and returns the path", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "nota-write-record-"));
    try {
      const outputPath = path.join(dir, "meeting.summary.md");
      const written = await writeOutputFromRecord(makeRecord({ outputPath }));

      expect(written).toBe(outputPath);
      const md = await readFile(outputPath, "utf-8");
      expect(md).toContain("# Rewritten Meeting");
      expect(md).toContain("**Tags:** rewrite");
      // Dates derive from the record, not the wall clock.
      expect(md).toContain("**Captured:** 2026-07-17");
      expect(md).toContain("**Transcribed:** 2026-07-18");
      expect(md).toContain("[00:00] **Speaker 1:** Hello world");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("falls back to the default path next to the source when outputPath is unset", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "nota-write-record-"));
    try {
      const record = makeRecord({
        sourcePath: path.join(dir, "meeting.m4a"),
        outputPath: undefined,
      });
      const written = await writeOutputFromRecord(record);
      expect(written).toBe(path.join(dir, "meeting.summary.md"));
      expect(await readFile(written, "utf-8")).toContain("# Rewritten Meeting");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
