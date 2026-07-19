import { mkdtemp, rm, readFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  applyEnrichmentToRecord,
  completeHistoryRecord,
  createHistoryRecord,
  findHistoryByHash,
  formatHistoryList,
  listHistoryRecords,
  loadHistoryRecord,
  mergeTags,
  setRecordSummary,
  setRecordTags,
  speakerClipPath,
  writeSpeakerClip,
} from "../../src/pipeline/history.js";
import type { CreateHistoryInput } from "../../src/pipeline/history.js";
import type { MeetingSummary } from "../../src/pipeline/summarize.js";

describe("history", () => {
  let historyDir: string;

  beforeEach(async () => {
    historyDir = await mkdtemp(path.join(tmpdir(), "nota-history-test-"));
  });

  afterEach(async () => {
    await rm(historyDir, { recursive: true, force: true });
  });

  it("creates and completes a history record", async () => {
    const record = await createHistoryRecord(
      {
        sourcePath: "/tmp/meeting.m4a",
        provider: "assemblyai",
        options: {
          diarize: true,
          identify: false,
          model: "gpt-4o",
        },
        durationMinutes: 12,
        transcriptText: "Hello world",
        segments: [{ start: 0, end: 1, text: "Hello world", speaker: "A" }],
        outputPath: "/tmp/meeting.summary.md",
      },
      historyDir,
    );

    expect(record.status).toBe("transcribed");
    expect(record.sourceName).toBe("meeting.m4a");

    const completed = await completeHistoryRecord(
      record.id,
      {
        summary: {
          title: "Short meeting",
          tags: ["sync"],
          narrative: "A short meeting.",
          keyTopics: ["Topic"],
          decisions: [],
          actionItems: [],
        },
        outputPath: "/tmp/meeting.summary.md",
      },
      historyDir,
    );

    expect(completed.status).toBe("completed");
    expect(completed.summary?.narrative).toBe("A short meeting.");
  });

  it("lists records newest first and loads by unique prefix", async () => {
    const first = await createHistoryRecord(
      {
        sourcePath: "/tmp/first.m4a",
        provider: "whisper",
        options: {
          diarize: false,
          identify: false,
          model: "gpt-4o-mini",
        },
        durationMinutes: 1,
        transcriptText: "First",
        segments: [],
      },
      historyDir,
    );
    // Ensure a distinct createdAt; same-millisecond creates tie under
    // listHistoryRecords' createdAt-only sort, making newest-first indeterminate.
    await new Promise((resolve) => setTimeout(resolve, 5));
    const second = await createHistoryRecord(
      {
        sourcePath: "/tmp/second.m4a",
        provider: "assemblyai",
        options: {
          diarize: true,
          identify: true,
          model: "gpt-4o",
        },
        durationMinutes: 2,
        transcriptText: "Second",
        segments: [],
      },
      historyDir,
    );

    const records = await listHistoryRecords(historyDir);
    expect(records.map((record) => record.id)).toEqual([second.id, first.id]);

    const loaded = await loadHistoryRecord(second.id.slice(0, -1), historyDir);
    expect(loaded.id).toBe(second.id);

    const list = formatHistoryList(records);
    expect(list).toContain("Created\tID\tProvider\tStatus\tSource");
    expect(list).toContain("second.m4a");
  });

  it("returns an empty list for a missing history directory", async () => {
    await rm(historyDir, { recursive: true, force: true });
    await expect(listHistoryRecords(historyDir)).resolves.toEqual([]);
  });

  it("persists capturedAt and round-trips it on read", async () => {
    const record = await createHistoryRecord(
      {
        sourcePath: "/tmp/recorded.m4a",
        provider: "assemblyai",
        options: { diarize: true, identify: false, model: "gpt-4o" },
        durationMinutes: 5,
        transcriptText: "Hi",
        segments: [],
        capturedAt: "2020-01-02T03:04:05.000Z",
      },
      historyDir,
    );
    expect(record.capturedAt).toBe("2020-01-02T03:04:05.000Z");

    const loaded = await loadHistoryRecord(record.id, historyDir);
    expect(loaded.capturedAt).toBe("2020-01-02T03:04:05.000Z");
  });

  it("stores null capturedAt when not provided", async () => {
    const record = await createHistoryRecord(
      {
        sourcePath: "/tmp/unknown.m4a",
        provider: "whisper",
        options: { diarize: false, identify: false, model: "gpt-4o" },
        durationMinutes: 1,
        transcriptText: "Hi",
        segments: [],
      },
      historyDir,
    );
    expect(record.capturedAt).toBeNull();
  });

  it("persists contentHash and round-trips it on read", async () => {
    const record = await createHistoryRecord(
      {
        sourcePath: "/tmp/hashed.m4a",
        provider: "assemblyai",
        options: { diarize: true, identify: false, model: "gpt-4o" },
        durationMinutes: 3,
        transcriptText: "Hi",
        segments: [],
        contentHash: "deadbeef",
      },
      historyDir,
    );
    expect(record.contentHash).toBe("deadbeef");

    const loaded = await loadHistoryRecord(record.id, historyDir);
    expect(loaded.contentHash).toBe("deadbeef");
  });

  describe("findHistoryByHash", () => {
    const HASH_A = "a".repeat(64);
    const HASH_B = "b".repeat(64);
    const HASH_C = "c".repeat(64);

    it("returns the newest record matching a content hash", async () => {
      const older = await createHistoryRecord(
        {
          sourcePath: "/tmp/older.m4a",
          provider: "assemblyai",
          options: { diarize: true, identify: false, model: "gpt-4o" },
          durationMinutes: 1,
          transcriptText: "Older",
          segments: [],
          contentHash: HASH_A,
        },
        historyDir,
      );
      // Distinct createdAt so newest-first ordering is deterministic.
      await new Promise((resolve) => setTimeout(resolve, 5));
      const newer = await createHistoryRecord(
        {
          sourcePath: "/tmp/newer.m4a",
          provider: "assemblyai",
          options: { diarize: true, identify: false, model: "gpt-4o" },
          durationMinutes: 1,
          transcriptText: "Newer",
          segments: [],
          contentHash: HASH_A,
        },
        historyDir,
      );

      const found = await findHistoryByHash(HASH_A, historyDir);
      expect(found?.id).toBe(newer.id);
      expect(found?.id).not.toBe(older.id);
    });

    it("returns null when no record matches the hash", async () => {
      await createHistoryRecord(
        {
          sourcePath: "/tmp/other.m4a",
          provider: "whisper",
          options: { diarize: false, identify: false, model: "gpt-4o" },
          durationMinutes: 1,
          transcriptText: "Other",
          segments: [],
          contentHash: HASH_B,
        },
        historyDir,
      );
      expect(await findHistoryByHash(HASH_C, historyDir)).toBeNull();
    });

    it("never matches legacy records that have no contentHash", async () => {
      await createHistoryRecord(
        {
          sourcePath: "/tmp/legacy.m4a",
          provider: "whisper",
          options: { diarize: false, identify: false, model: "gpt-4o" },
          durationMinutes: 1,
          transcriptText: "Legacy",
          segments: [],
        },
        historyDir,
      );
      // An empty query hash must not coincidentally match an undefined field.
      expect(await findHistoryByHash("", historyDir)).toBeNull();
    });

    it("returns null for a malformed (non-hex) hash", async () => {
      await createHistoryRecord(
        {
          sourcePath: "/tmp/real.m4a",
          provider: "assemblyai",
          options: { diarize: true, identify: false, model: "gpt-4o" },
          durationMinutes: 1,
          transcriptText: "Real",
          segments: [],
          contentHash: HASH_A,
        },
        historyDir,
      );
      // Too short, and contains non-hex chars — must be rejected, not matched.
      expect(await findHistoryByHash("not-a-real-hash", historyDir)).toBeNull();
    });
  });

  describe("enrichment helpers", () => {
    const SUMMARY: MeetingSummary = {
      title: "Planning Sync",
      tags: ["planning"],
      narrative: "We planned things.",
      keyTopics: ["**Roadmap** — Q3"],
      decisions: [],
      actionItems: [],
    };

    function transcribedInput(
      overrides: Partial<CreateHistoryInput> = {},
    ): CreateHistoryInput {
      return {
        sourcePath: "/tmp/meeting.m4a",
        provider: "assemblyai",
        options: { diarize: true, identify: false, model: "gpt-4o" },
        durationMinutes: 10,
        transcriptText: "Hello world",
        segments: [],
        ...overrides,
      };
    }

    describe("mergeTags", () => {
      it("keeps manual tags first and appends generated ones", () => {
        expect(mergeTags(["ops", "q3"], ["planning", "roadmap"])).toEqual([
          "ops",
          "q3",
          "planning",
          "roadmap",
        ]);
      });

      it("dedups case-insensitively and lowercases the union", () => {
        expect(mergeTags(["Planning", "OPS"], ["planning", "budget"])).toEqual([
          "planning",
          "ops",
          "budget",
        ]);
      });

      it("drops empty entries and caps the union at 8", () => {
        const manual = ["a", "b", "c", "d", " "];
        const generated = ["e", "f", "g", "h", "i", "j"];
        expect(mergeTags(manual, generated)).toEqual([
          "a",
          "b",
          "c",
          "d",
          "e",
          "f",
          "g",
          "h",
        ]);
      });
    });

    describe("setRecordSummary", () => {
      it("sets the summary, flips status to completed, and appends usage", async () => {
        const record = await createHistoryRecord(transcribedInput(), historyDir);
        expect(record.status).toBe("transcribed");

        const updated = await setRecordSummary(
          record.id,
          {
            summary: SUMMARY,
            summaryEdited: false,
            usage: [
              {
                modelId: "gpt-5-mini",
                task: "summary",
                provider: "assemblyai",
                calls: 1,
                tokensIn: 100,
                tokensOut: 50,
                costUSD: null,
                estimated: false,
              },
            ],
            outputPath: "/tmp/meeting.summary.md",
          },
          historyDir,
        );

        expect(updated.status).toBe("completed");
        expect(updated.summary?.narrative).toBe("We planned things.");
        expect(updated.summaryEdited).toBe(false);
        expect(updated.usage).toHaveLength(1);
        expect(updated.outputPath).toBe("/tmp/meeting.summary.md");

        // Persisted, not just returned (record is truth).
        const loaded = await loadHistoryRecord(record.id, historyDir);
        expect(loaded.status).toBe("completed");
        expect(loaded.summary?.title).toBe("Planning Sync");
      });

      it("leaves edited flags untouched when not provided", async () => {
        const record = await createHistoryRecord(transcribedInput(), historyDir);
        await applyEnrichmentToRecord(record.id, { tagsEdited: true }, historyDir);

        const updated = await setRecordSummary(
          record.id,
          { summary: SUMMARY },
          historyDir,
        );
        expect(updated.tagsEdited).toBe(true);
      });
    });

    describe("setRecordTags", () => {
      it("stores tags on a transcript-only record without completing it", async () => {
        const record = await createHistoryRecord(transcribedInput(), historyDir);

        const updated = await setRecordTags(
          record.id,
          { tags: ["planning", "roadmap"] },
          historyDir,
        );

        // Tags live in a stub summary container; status is untouched — only
        // a summary completes a record (E3-d).
        expect(updated.summary?.tags).toEqual(["planning", "roadmap"]);
        expect(updated.summary?.narrative).toBe("");
        expect(updated.status).toBe("transcribed");
      });

      it("replaces tags on a completed record, keeping the summary intact", async () => {
        const record = await createHistoryRecord(transcribedInput(), historyDir);
        await completeHistoryRecord(
          record.id,
          { summary: SUMMARY, outputPath: "/tmp/meeting.summary.md" },
          historyDir,
        );

        const updated = await setRecordTags(
          record.id,
          { tags: ["budget"], tagsEdited: false },
          historyDir,
        );
        expect(updated.summary?.tags).toEqual(["budget"]);
        expect(updated.summary?.narrative).toBe("We planned things.");
        expect(updated.status).toBe("completed");
        expect(updated.tagsEdited).toBe(false);
      });
    });

    describe("applyEnrichmentToRecord", () => {
      it("applies a summary edit, sets the flag as given, and completes the record", async () => {
        const record = await createHistoryRecord(transcribedInput(), historyDir);

        const updated = await applyEnrichmentToRecord(
          record.id,
          { summary: "Hand-edited narrative.", summaryEdited: true },
          historyDir,
        );

        expect(updated.summary?.narrative).toBe("Hand-edited narrative.");
        expect(updated.summaryEdited).toBe(true);
        expect(updated.status).toBe("completed");

        const loaded = await loadHistoryRecord(record.id, historyDir);
        expect(loaded.summary?.narrative).toBe("Hand-edited narrative.");
        expect(loaded.summaryEdited).toBe(true);
      });

      it("replaces tags verbatim (edits do not merge) and does not flip status", async () => {
        const record = await createHistoryRecord(transcribedInput(), historyDir);
        await setRecordTags(record.id, { tags: ["old", "tags"] }, historyDir);

        const updated = await applyEnrichmentToRecord(
          record.id,
          { tags: ["only-this"], tagsEdited: true },
          historyDir,
        );

        expect(updated.summary?.tags).toEqual(["only-this"]);
        expect(updated.tagsEdited).toBe(true);
        expect(updated.status).toBe("transcribed");
      });

      it("preserves existing summary fields when patching only the narrative", async () => {
        const record = await createHistoryRecord(transcribedInput(), historyDir);
        await completeHistoryRecord(
          record.id,
          { summary: SUMMARY, outputPath: "/tmp/meeting.summary.md" },
          historyDir,
        );

        const updated = await applyEnrichmentToRecord(
          record.id,
          { summary: "Edited.", summaryEdited: true },
          historyDir,
        );
        expect(updated.summary?.title).toBe("Planning Sync");
        expect(updated.summary?.tags).toEqual(["planning"]);
        expect(updated.summary?.keyTopics).toEqual(["**Roadmap** — Q3"]);
      });

      it("enriches legacy records that predate the enrichment fields", async () => {
        // A legacy record has no contentHash, usage, or edited flags — only
        // transcriptText is required for enrichment (E3-e).
        const record = await createHistoryRecord(transcribedInput(), historyDir);
        expect(record.summaryEdited).toBeUndefined();
        expect(record.tagsEdited).toBeUndefined();

        const updated = await applyEnrichmentToRecord(
          record.id,
          { tags: ["fresh"], tagsEdited: true },
          historyDir,
        );
        expect(updated.summary?.tags).toEqual(["fresh"]);
        expect(updated.tagsEdited).toBe(true);
      });
    });
  });

  it("writes a per-speaker clip under <id>.assets and returns a relative pointer", async () => {
    const rel = await writeSpeakerClip(
      "20260604-000000Z-abcd1234",
      "Speaker 1",
      new Int16Array([1, 2, 3]),
      historyDir,
    );
    expect(rel).toBe("20260604-000000Z-abcd1234.assets/Speaker 1.pcm");
    const abs = speakerClipPath("20260604-000000Z-abcd1234", "Speaker 1", historyDir);
    const buf = await readFile(abs);
    expect(buf.length).toBe(6); // 3 Int16 samples = 6 bytes
  });

  it("persists speakerClipsPcm and records relative clip pointers on the record", async () => {
    const record = await createHistoryRecord(
      {
        sourcePath: "/tmp/clips.m4a",
        provider: "assemblyai",
        options: { diarize: true, identify: true, model: "gpt-4o" },
        durationMinutes: 4,
        transcriptText: "hi",
        segments: [],
        speakerClipsPcm: { "Speaker 1": new Int16Array([4, 5]) },
      },
      historyDir,
    );
    expect(record.speakerClips?.["Speaker 1"]).toBe(`${record.id}.assets/Speaker 1.pcm`);
    const loaded = await loadHistoryRecord(record.id, historyDir);
    expect(loaded.speakerClips?.["Speaker 1"]).toBe(`${record.id}.assets/Speaker 1.pcm`);
    const buf = await readFile(speakerClipPath(record.id, "Speaker 1", historyDir));
    expect(buf.length).toBe(4); // 2 Int16 samples
  });
});
