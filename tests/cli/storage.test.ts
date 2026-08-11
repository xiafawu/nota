/**
 * `nota history storage | delete-audio | delete` (XIA-436).
 *
 * The stream split is part of the contract, so it is asserted here rather than
 * assumed: scriptable rows on stdout, confirmations and totals on stderr.
 */

import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { PassThrough } from "node:stream";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  StorageError,
  audioStaysLine,
  deleteAudioCommand,
  deleteRecordCommand,
  storageCommand,
} from "../../src/cli/storage.js";
import { recordAssetsDir } from "../../src/pipeline/storage.js";
import { loadHistoryRecord } from "../../src/pipeline/history.js";
import { buildStorageFixture } from "../../scripts/storage-summary-fixture.js";

const exists = (file: string) => access(file).then(() => true, () => false);

describe("history storage verbs", () => {
  let historyDir: string;
  let out: string[];
  let err: string[];

  beforeEach(async () => {
    historyDir = await mkdtemp(path.join(tmpdir(), "nota-storage-cli-"));
    out = [];
    err = [];
  });

  afterEach(async () => {
    await rm(historyDir, { recursive: true, force: true });
  });

  const io = (overrides: Record<string, unknown> = {}) => ({
    historyDir,
    out: (line: string) => out.push(line),
    write: (line: string) => err.push(line),
    ...overrides,
  });

  async function seedRecord(
    id: string,
    options: {
      createdAt?: string;
      audioBytes?: number;
      withAudio?: boolean;
      outputPath?: string;
      clipBytes?: number;
    } = {},
  ): Promise<void> {
    const {
      createdAt = "2026-01-01T00:00:00.000Z",
      audioBytes = 2048,
      withAudio = true,
      outputPath,
      clipBytes = 0,
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
      sourcePath: "/tmp/source.m4a",
      sourceName: "recording.caf",
      provider: "assemblyai",
      options: { diarize: false, identify: false, model: "gpt-5-mini" },
      durationMinutes: 3,
      transcriptText: "kept",
      segments: [],
      status: "transcribed",
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

  describe("storage", () => {
    it("prints rows on stdout and the totals on stderr, oldest first", async () => {
      await seedRecord("older", { createdAt: "2026-01-01T00:00:00.000Z", audioBytes: 1024 });
      await seedRecord("newer", { createdAt: "2026-02-01T00:00:00.000Z", audioBytes: 2048 });

      await storageCommand(io());

      expect(out).toHaveLength(2);
      expect(out[0]).toContain("older");
      expect(out[1]).toContain("newer");
      expect(err[0]).toBe("Created\tID\tAudio\tTotal\tSource");
      expect(err.join("\n")).toContain("2 record(s)");
      expect(err.join("\n")).toContain("Nota never deletes recordings on its own.");
    });

    it("says audio not kept for a legacy record instead of zero", async () => {
      await seedRecord("legacy", { withAudio: false });

      await storageCommand(io());

      // The audio COLUMN is what has to read in words — `not.toContain("0 B")`
      // was true of every row that has any audio at all and could not fail.
      expect(out[0].split("\t")[2]).toBe("audio not kept");
    });

    it("emits the whole summary as JSON for the app", async () => {
      await seedRecord("one", { audioBytes: 4096 });

      const summary = await storageCommand(io({ json: true }));

      const parsed = JSON.parse(out.join("\n"));
      // The app decodes exactly what this verb computes — one implementation.
      expect(parsed.totalBytes).toBe(summary.totalBytes);
      expect(parsed.count).toBe(1);
      expect(parsed.audioBytes).toBe(4096);
    });

    it("emits exactly the JSON the committed Swift fixture decodes", async () => {
      // The macOS `StoredStorageSummary` test decodes
      // macos/Nota/UI/Tests/Fixtures/storage-summary.json, and that file is
      // this verb's own output rather than a hand-copy — a hand-copy had
      // already drifted (it was missing the `status` key every real row
      // carries). Rebuilding and comparing is what makes the two sides one
      // contract instead of two beliefs about a shape.
      const fixturePath = path.join(
        import.meta.dirname,
        "../../macos/Nota/UI/Tests/Fixtures/storage-summary.json",
      );
      const committed = JSON.parse(await readFile(fixturePath, "utf-8"));

      expect(JSON.parse(await buildStorageFixture())).toEqual(committed);
    });

    it("names the bytes no record can account for, and never removes them", async () => {
      await seedRecord("kept", { audioBytes: 1024 });
      const orphan = recordAssetsDir("nobody", historyDir);
      await mkdir(orphan, { recursive: true });
      await writeFile(path.join(orphan, "recording.caf"), Buffer.alloc(65536));

      await storageCommand(io());

      // On stdout with the rows: the name is the only handle anyone has on it.
      const orphanRow = out.find((line) => line.includes("nobody"));
      expect(orphanRow).toBeDefined();
      expect(orphanRow!.split("\t")[2]).toBe("no record");
      expect(err.join("\n")).toContain("no readable record names");
      // Named, never touched.
      expect(await exists(path.join(orphan, "recording.caf"))).toBe(true);
    });

    it("still reports a store whose only contents are leftovers", async () => {
      const orphan = recordAssetsDir("nobody", historyDir);
      await mkdir(orphan, { recursive: true });
      await writeFile(path.join(orphan, "recording.caf"), Buffer.alloc(2048));

      await storageCommand(io());

      expect(err.join("\n")).not.toContain("No Nota history records found.");
      expect(out.join("\n")).toContain("nobody");
      expect(err.join("\n")).toContain("2.0 KB");
    });

    it("survives a record it cannot parse rather than taking the verb down", async () => {
      await seedRecord("fine", { audioBytes: 512 });
      await writeFile(path.join(historyDir, "corrupt.json"), "{{{", "utf-8");

      await expect(storageCommand(io())).resolves.toBeDefined();
      expect(out.join("\n")).toContain("fine");
      expect(out.join("\n")).toContain("corrupt");
    });

    it("lets the delete verbs work when one other record is corrupt", async () => {
      // `resolveTargets` computes the whole store even for a single named id,
      // so one bad file used to take BOTH delete verbs down with it.
      await seedRecord("target", { audioBytes: 512 });
      await writeFile(path.join(historyDir, "corrupt.json"), "not json", "utf-8");

      await deleteAudioCommand({ id: "target", yes: true }, io());

      expect(
        await exists(path.join(recordAssetsDir("target", historyDir), "recording.caf")),
      ).toBe(false);
    });
  });

  describe("delete-audio", () => {
    it("asks before deleting and keeps the record when the answer is no", async () => {
      await seedRecord("keep", { audioBytes: 2048 });

      await deleteAudioCommand(
        { id: "keep" },
        io({ ask: async () => "n" }),
      );

      expect(err.join("\n")).toContain("Cancelled. Nothing was deleted.");
      expect(
        await exists(path.join(recordAssetsDir("keep", historyDir), "recording.caf")),
      ).toBe(true);
    });

    it("names the bytes, what stays, and that it cannot be undone", async () => {
      await seedRecord("keep", { audioBytes: 2048 });

      await deleteAudioCommand({ id: "keep" }, io({ ask: async () => "n" }));

      const prompt = err.join("\n");
      expect(prompt).toContain("2.0 KB to delete");
      expect(prompt).toContain("The transcript, summary and markers stay.");
      expect(prompt).toContain("This cannot be undone.");
    });

    it("deletes the audio and keeps the record when confirmed", async () => {
      await seedRecord("go", { audioBytes: 2048 });

      await deleteAudioCommand({ id: "go" }, io({ ask: async () => "y" }));

      expect(
        await exists(path.join(recordAssetsDir("go", historyDir), "recording.caf")),
      ).toBe(false);
      expect((await loadHistoryRecord("go", historyDir)).transcriptText).toBe("kept");
      expect(err.join("\n")).toContain("Record kept.");
    });

    it("--yes skips the prompt entirely", async () => {
      await seedRecord("go", { audioBytes: 1024 });
      let asked = false;

      await deleteAudioCommand(
        { id: "go", yes: true },
        io({ ask: async () => { asked = true; return "n"; } }),
      );

      expect(asked).toBe(false);
      expect(
        await exists(path.join(recordAssetsDir("go", historyDir), "recording.caf")),
      ).toBe(false);
    });

    it("refuses to delete non-interactively without --yes", async () => {
      await seedRecord("go", { audioBytes: 1024 });

      await expect(
        deleteAudioCommand({ id: "go" }, { historyDir, out: () => {}, write: () => {}, isTTY: false }),
      ).rejects.toThrow(/--yes/);

      expect(
        await exists(path.join(recordAssetsDir("go", historyDir), "recording.caf")),
      ).toBe(true);
    });

    it("exits non-zero for a record that does not exist", async () => {
      await expect(
        deleteAudioCommand({ id: "nope", yes: true }, io()),
      ).rejects.toThrow(/History record not found/);
    });

    it("says so quietly when the record keeps no audio", async () => {
      await seedRecord("legacy", { withAudio: false });

      await deleteAudioCommand({ id: "legacy", yes: true }, io());

      expect(err.join("\n")).toContain("keep no audio");
      expect(err.join("\n")).toContain("No audio to delete.");
    });

    it("says the per-speaker voice clips stay, and how many", async () => {
      // The clips are raw audio of the same people, and this verb keeps them.
      // "only the recording goes" is not the whole truth for someone deleting
      // audio for privacy.
      await seedRecord("clips", { audioBytes: 2048, clipBytes: 700 });

      await deleteAudioCommand({ id: "clips" }, io({ ask: async () => "n" }));

      const prompt = err.join("\n");
      expect(prompt).toContain("1 per-speaker voice clip(s)");
      expect(prompt).toContain("700 B");
      // And no clip is claimed when the record has none.
      expect(
        audioStaysLine([{ speakerClipCount: 0, speakerClipBytes: 0 } as never]),
      ).toBe("The transcript, summary and markers stay.");
    });

    it("reads the answer off the real stdin when nothing is injected", async () => {
      // The `createInterface` branch — the one a real terminal takes — had no
      // test at all: every other case here injects `ask`. This drives the
      // actual readline prompt, its answer, and the `rl.close()` in the
      // `finally` (a leaked interface holds stdin open and hangs the CLI).
      await seedRecord("typed", { audioBytes: 1024 });
      const audio = path.join(recordAssetsDir("typed", historyDir), "recording.caf");
      const fakeStdin = new PassThrough();
      const realStdin = Object.getOwnPropertyDescriptor(process, "stdin")!;
      const realWrite = process.stderr.write;
      Object.defineProperty(process, "stdin", { value: fakeStdin, configurable: true });
      // readline writes the prompt to stderr; keep it out of the test output.
      process.stderr.write = (() => true) as typeof process.stderr.write;

      try {
        const run = deleteAudioCommand({ id: "typed" }, io({ isTTY: true }));
        await new Promise((resolve) => setImmediate(resolve));
        fakeStdin.write("y\n");
        await run;
      } finally {
        process.stderr.write = realWrite;
        Object.defineProperty(process, "stdin", realStdin);
      }

      expect(await exists(audio)).toBe(false);
      // The interface was closed: nothing of readline's is still on stdin.
      expect(fakeStdin.listenerCount("data")).toBe(0);
    });

    it("takes anything but yes as no, off the real stdin", async () => {
      await seedRecord("typed", { audioBytes: 1024 });
      const audio = path.join(recordAssetsDir("typed", historyDir), "recording.caf");
      const fakeStdin = new PassThrough();
      const realStdin = Object.getOwnPropertyDescriptor(process, "stdin")!;
      const realWrite = process.stderr.write;
      Object.defineProperty(process, "stdin", { value: fakeStdin, configurable: true });
      process.stderr.write = (() => true) as typeof process.stderr.write;

      try {
        const run = deleteAudioCommand({ id: "typed" }, io({ isTTY: true }));
        await new Promise((resolve) => setImmediate(resolve));
        fakeStdin.write("\n");
        await run;
      } finally {
        process.stderr.write = realWrite;
        Object.defineProperty(process, "stdin", realStdin);
      }

      expect(await exists(audio)).toBe(true);
      expect(err.join("\n")).toContain("Cancelled. Nothing was deleted.");
    });

    it("--older-than prints every id and the total before asking", async () => {
      await seedRecord("ancient-a", { createdAt: "2025-01-01T00:00:00.000Z", audioBytes: 1024 });
      await seedRecord("ancient-b", { createdAt: "2025-02-01T00:00:00.000Z", audioBytes: 1024 });
      await seedRecord("fresh", { createdAt: "2026-05-30T00:00:00.000Z", audioBytes: 1024 });

      const questions: string[] = [];
      await deleteAudioCommand(
        { olderThan: "90d" },
        io({
          now: new Date("2026-06-01T00:00:00.000Z"),
          ask: async (q: string) => { questions.push(q); return "n"; },
        }),
      );

      // Every selected id printed, and only the selected ones.
      expect(out.join("\n")).toContain("ancient-a");
      expect(out.join("\n")).toContain("ancient-b");
      expect(out.join("\n")).not.toContain("fresh");
      // The total, before the question was asked.
      expect(err.join("\n")).toContain("2 record(s), 2.0 KB to delete");
      expect(questions).toHaveLength(1);
    });
  });

  describe("delete", () => {
    it("removes the record and its assets, and keeps the exported markdown", async () => {
      const exported = path.join(historyDir, "notes.summary.md");
      await writeFile(exported, "# owner's notes", "utf-8");
      await seedRecord("bye", { audioBytes: 2048, outputPath: exported });

      await deleteRecordCommand({ id: "bye" }, io({ ask: async () => "y" }));

      expect(await exists(path.join(historyDir, "bye.json"))).toBe(false);
      expect(await exists(recordAssetsDir("bye", historyDir))).toBe(false);
      expect(await exists(exported)).toBe(true);
      expect(err.join("\n")).toContain(`Kept exported markdown: ${exported}`);
    });

    it("says both the audio and the transcript go, and the .md stays", async () => {
      await seedRecord("bye", { audioBytes: 2048 });

      await deleteRecordCommand({ id: "bye" }, io({ ask: async () => "n" }));

      const prompt = err.join("\n");
      expect(prompt).toContain(
        "The transcript and its audio both go; the exported .md file stays.",
      );
      expect(prompt).toContain("This cannot be undone.");
      expect(await exists(path.join(historyDir, "bye.json"))).toBe(true);
    });

    it("refuses to delete non-interactively without --yes", async () => {
      await seedRecord("bye", { audioBytes: 1024 });

      await expect(
        deleteRecordCommand({ id: "bye" }, { historyDir, out: () => {}, write: () => {}, isTTY: false }),
      ).rejects.toThrow(/--yes/);

      expect(await exists(path.join(historyDir, "bye.json"))).toBe(true);
    });

    it("--older-than selects only records older than the age", async () => {
      await seedRecord("ancient", { createdAt: "2025-01-01T00:00:00.000Z", audioBytes: 1024 });
      await seedRecord("fresh", { createdAt: "2026-05-30T00:00:00.000Z", audioBytes: 1024 });

      await deleteRecordCommand(
        { olderThan: "90d", yes: true },
        io({ now: new Date("2026-06-01T00:00:00.000Z") }),
      );

      expect(await exists(path.join(historyDir, "ancient.json"))).toBe(false);
      expect(await exists(path.join(historyDir, "fresh.json"))).toBe(true);
    });

    it("requires a target, and refuses both at once", async () => {
      await expect(deleteRecordCommand({}, io())).rejects.toThrow(StorageError);
      await expect(
        deleteRecordCommand({ id: "x", olderThan: "90d" }, io()),
      ).rejects.toThrow(/not both/);
    });
  });
});
