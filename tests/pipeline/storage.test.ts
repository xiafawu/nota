/**
 * Storage accounting and the two deletion primitives (XIA-436).
 *
 * Deletion is the one irreversible thing this app does, so every verb here is
 * pinned by what it did NOT delete as much as by what it did.
 */

import { access, mkdir, mkdtemp, rm, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  computeStorage,
  deleteRecord,
  deleteRecordAudio,
  formatBytes,
  keptAudioPath,
  parseOlderThan,
  selectOlderThan,
  recordAssetsDir,
} from "../../src/pipeline/storage.js";
import { listHistoryRecords, loadHistoryRecord } from "../../src/pipeline/history.js";

const exists = (file: string) => access(file).then(() => true, () => false);

describe("storage", () => {
  let historyDir: string;

  beforeEach(async () => {
    historyDir = await mkdtemp(path.join(tmpdir(), "nota-storage-test-"));
  });

  afterEach(async () => {
    await rm(historyDir, { recursive: true, force: true });
  });

  /**
   * Write a record the record-first way: `<id>.json` plus an `<id>.assets/`
   * folder holding `recording.caf` and (optionally) a speaker clip.
   */
  async function seedRecord(
    id: string,
    options: {
      createdAt?: string;
      audioBytes?: number;
      /** Omit to write a legacy record: no audioPath, only sourcePath. */
      withAudio?: boolean;
      clipBytes?: number;
      outputPath?: string;
      sourcePath?: string;
    } = {},
  ): Promise<void> {
    const {
      createdAt = "2026-01-01T00:00:00.000Z",
      audioBytes = 2048,
      withAudio = true,
      clipBytes = 0,
      outputPath,
      sourcePath = "/tmp/original.m4a",
    } = options;

    const assets = recordAssetsDir(id, historyDir);
    await mkdir(assets, { recursive: true });
    if (withAudio) {
      await writeFile(path.join(assets, "recording.caf"), Buffer.alloc(audioBytes));
    }
    if (clipBytes > 0) {
      await writeFile(path.join(assets, "Speaker 1.pcm"), Buffer.alloc(clipBytes));
    }

    const record: Record<string, unknown> = {
      id,
      createdAt,
      updatedAt: createdAt,
      capturedAt: createdAt,
      sourcePath,
      sourceName: "recording.caf",
      provider: "assemblyai",
      options: { diarize: true, identify: false, model: "gpt-5-mini" },
      durationMinutes: 5,
      transcriptText: "the transcript survives",
      segments: [{ start: 0, end: 1, text: "the transcript survives" }],
      summary: {
        title: "A meeting",
        tags: ["one"],
        narrative: "narrative",
        keyTopics: [],
        decisions: [],
        actionItems: [],
      },
      speakerClips: clipBytes > 0 ? { "Speaker 1": `${id}.assets/Speaker 1.pcm` } : undefined,
      status: "done",
    };
    if (withAudio) {
      record.audioPath = "recording.caf";
      record.audioBytes = audioBytes;
    }
    if (outputPath) record.outputPath = outputPath;

    await writeFile(
      path.join(historyDir, `${id}.json`),
      JSON.stringify(record, null, 2),
      "utf-8",
    );
  }

  describe("computeStorage", () => {
    it("counts the assets folder and the record, oldest first", async () => {
      await seedRecord("b-newer", { createdAt: "2026-03-01T00:00:00.000Z", audioBytes: 1000 });
      await seedRecord("a-older", { createdAt: "2026-01-01T00:00:00.000Z", audioBytes: 4000 });

      const summary = await computeStorage(historyDir);

      expect(summary.count).toBe(2);
      expect(summary.records.map((r) => r.id)).toEqual(["a-older", "b-newer"]);
      expect(summary.audioBytes).toBe(5000);
      expect(summary.oldestCreatedAt).toBe("2026-01-01T00:00:00.000Z");
      // Total is the audio plus each record's own JSON.
      expect(summary.totalBytes).toBeGreaterThan(summary.audioBytes);
      const older = summary.records[0];
      expect(older.totalBytes).toBe(older.assetsBytes + older.recordBytes);
    });

    it("counts speaker clips in the assets total but not as audio", async () => {
      await seedRecord("with-clip", { audioBytes: 1000, clipBytes: 500 });

      const [row] = (await computeStorage(historyDir)).records;

      expect(row.audioBytes).toBe(1000);
      expect(row.assetsBytes).toBe(1500);
    });

    it("reads a legacy record as audio not kept and never counts its sourcePath", async () => {
      // A legacy record's `sourcePath` is the OWNER's own file, outside the
      // store. It is neither counted nor deletable.
      const ownersFile = path.join(historyDir, "not-in-the-store.m4a");
      await writeFile(ownersFile, Buffer.alloc(9999));
      await seedRecord("legacy", { withAudio: false, sourcePath: ownersFile });

      const summary = await computeStorage(historyDir);

      expect(summary.records[0].audioBytes).toBeNull();
      expect(summary.audioBytes).toBe(0);
      expect(summary.totalBytes).toBeLessThan(9999);
    });

    it("counts this month against the calendar month of now", async () => {
      await seedRecord("old", { createdAt: "2026-01-15T00:00:00.000Z", audioBytes: 1000 });
      await seedRecord("new", { createdAt: "2026-03-20T00:00:00.000Z", audioBytes: 2000 });

      const summary = await computeStorage(historyDir, new Date(2026, 2, 25));

      expect(summary.thisMonthBytes).toBeGreaterThan(2000);
      expect(summary.thisMonthBytes).toBeLessThan(summary.totalBytes);
    });

    it("is empty rather than throwing when the store does not exist", async () => {
      const summary = await computeStorage(path.join(historyDir, "nope"));
      expect(summary).toMatchObject({ count: 0, totalBytes: 0, oldestCreatedAt: null });
    });
  });

  describe("keptAudioPath", () => {
    it("refuses an audioPath that climbs out of the assets folder", () => {
      // The value is read off a JSON file and handed to unlink. A record must
      // not be able to aim a delete at an arbitrary file.
      expect(
        keptAudioPath({ id: "x", audioPath: "../../../etc/passwd" }, historyDir),
      ).toBeNull();
    });

    it("never resolves to a legacy record's sourcePath", () => {
      expect(keptAudioPath({ id: "legacy", audioPath: undefined }, historyDir)).toBeNull();
    });
  });

  describe("deleteRecordAudio", () => {
    it("removes the audio and leaves transcript, summary and clips intact", async () => {
      await seedRecord("keep-me", {
        audioBytes: 2048,
        clipBytes: 300,
        outputPath: "/tmp/notes.summary.md",
      });

      const result = await deleteRecordAudio("keep-me", historyDir);

      expect(result).toMatchObject({ id: "keep-me", deleted: true, freedBytes: 2048 });
      expect(
        await exists(path.join(recordAssetsDir("keep-me", historyDir), "recording.caf")),
      ).toBe(false);

      // What must SURVIVE — the containment rule's whole point.
      const record = await loadHistoryRecord("keep-me", historyDir);
      expect(record.transcriptText).toBe("the transcript survives");
      expect(record.segments).toHaveLength(1);
      expect(record.summary?.title).toBe("A meeting");
      expect(record.speakerClips).toEqual({ "Speaker 1": "keep-me.assets/Speaker 1.pcm" });
      expect(record.outputPath).toBe("/tmp/notes.summary.md");
      expect(record.status).toBe("done");
      // The speaker clip is not audio and does not go with it.
      expect(
        await exists(path.join(recordAssetsDir("keep-me", historyDir), "Speaker 1.pcm")),
      ).toBe(true);
      // The record now reads "audio not kept".
      expect(record.audioPath).toBeUndefined();
      expect(record.audioBytes).toBeUndefined();
      expect((await computeStorage(historyDir)).records[0].audioBytes).toBeNull();
    });

    it("still lists and loads in both directions after the audio goes", async () => {
      await seedRecord("readable", { audioBytes: 1024 });
      await deleteRecordAudio("readable", historyDir);

      const listed = await listHistoryRecords(historyDir);
      expect(listed).toHaveLength(1);
      expect(listed[0].transcriptText).toBe("the transcript survives");
    });

    it("is a no-op on a record that keeps no audio, and never touches sourcePath", async () => {
      const ownersFile = path.join(historyDir, "owners-own.m4a");
      await writeFile(ownersFile, Buffer.alloc(1234));
      await seedRecord("legacy", { withAudio: false, sourcePath: ownersFile });

      const result = await deleteRecordAudio("legacy", historyDir);

      expect(result).toMatchObject({ deleted: false, freedBytes: 0 });
      expect(await exists(ownersFile)).toBe(true);
      expect((await loadHistoryRecord("legacy", historyDir)).sourcePath).toBe(ownersFile);
    });

    it("throws for a record that does not exist", async () => {
      await expect(deleteRecordAudio("nope", historyDir)).rejects.toThrow(
        /History record not found/,
      );
    });
  });

  describe("deleteRecord", () => {
    it("leaves no assets folder behind and never touches the exported markdown", async () => {
      const exported = path.join(historyDir, "exported.summary.md");
      await writeFile(exported, "# notes the owner keeps", "utf-8");
      await seedRecord("goodbye", { audioBytes: 1000, clipBytes: 200, outputPath: exported });

      const result = await deleteRecord("goodbye", historyDir);

      expect(result.id).toBe("goodbye");
      expect(result.freedBytes).toBeGreaterThan(1200);
      expect(result.outputPath).toBe(exported);
      // Nothing of the record is left — no orphaned assets folder.
      expect(await exists(path.join(historyDir, "goodbye.json"))).toBe(false);
      expect(await exists(recordAssetsDir("goodbye", historyDir))).toBe(false);
      // The .md lives outside ~/.nota and is NEVER deleted by Nota.
      expect(await exists(exported)).toBe(true);
      expect(await readFile(exported, "utf-8")).toBe("# notes the owner keeps");
    });

    it("deletes only the named record", async () => {
      await seedRecord("one", { audioBytes: 100 });
      await seedRecord("two", { audioBytes: 100 });

      await deleteRecord("one", historyDir);

      const remaining = await listHistoryRecords(historyDir);
      expect(remaining.map((r) => r.id)).toEqual(["two"]);
      expect(await exists(recordAssetsDir("two", historyDir))).toBe(true);
    });

    it("throws for a record that does not exist", async () => {
      await expect(deleteRecord("nope", historyDir)).rejects.toThrow(
        /History record not found/,
      );
    });
  });

  describe("parseOlderThan / selectOlderThan", () => {
    const now = new Date("2026-06-01T00:00:00.000Z");

    it("parses days, weeks, months and years", () => {
      expect(parseOlderThan("90d", now).toISOString()).toBe("2026-03-03T00:00:00.000Z");
      expect(parseOlderThan("1w", now).toISOString()).toBe("2026-05-25T00:00:00.000Z");
      expect(parseOlderThan("1m", now).toISOString()).toBe("2026-05-02T00:00:00.000Z");
      expect(parseOlderThan("1y", now).toISOString()).toBe("2025-06-01T00:00:00.000Z");
    });

    it("refuses a value it cannot read rather than guessing", () => {
      expect(() => parseOlderThan("ninety days", now)).toThrow(/Invalid --older-than/);
      expect(() => parseOlderThan("90", now)).toThrow(/Invalid --older-than/);
    });

    it("selects strictly older records and never one it cannot date", () => {
      const rows = [
        { id: "ancient", createdAt: "2025-01-01T00:00:00.000Z" },
        { id: "recent", createdAt: "2026-05-30T00:00:00.000Z" },
        { id: "undated", createdAt: "not a date" },
      ] as never[];

      const selected = selectOlderThan(rows, parseOlderThan("90d", now));

      expect(selected.map((r: { id: string }) => r.id)).toEqual(["ancient"]);
    });
  });

  describe("formatBytes", () => {
    it("reads in binary units", () => {
      expect(formatBytes(512)).toBe("512 B");
      expect(formatBytes(1536)).toBe("1.5 KB");
      expect(formatBytes(5 * 1024 * 1024)).toBe("5.0 MB");
    });
  });
});
