import { mkdtemp, rm, readFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  completeHistoryRecord,
  createHistoryRecord,
  findHistoryByHash,
  formatHistoryList,
  listHistoryRecords,
  loadHistoryRecord,
  speakerClipPath,
  writeSpeakerClip,
} from "../../src/pipeline/history.js";

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
