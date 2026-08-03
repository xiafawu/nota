import { mkdtemp, rm, readFile, writeFile, access } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  createHistoryRecord,
  loadHistoryRecord,
  renameRecordSpeaker,
  speakerClipPath,
  writeSpeakerClip,
} from "../../src/pipeline/history.js";
import type { CreateHistoryInput } from "../../src/pipeline/history.js";

async function exists(p: string): Promise<boolean> {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

describe("renameRecordSpeaker", () => {
  let historyDir: string;
  let outputDir: string;

  beforeEach(async () => {
    historyDir = await mkdtemp(path.join(tmpdir(), "nota-rename-test-"));
    outputDir = await mkdtemp(path.join(tmpdir(), "nota-rename-out-"));
  });

  afterEach(async () => {
    await rm(historyDir, { recursive: true, force: true });
    await rm(outputDir, { recursive: true, force: true });
  });

  async function makeRecord(
    overrides: Partial<CreateHistoryInput> = {},
  ): Promise<string> {
    const record = await createHistoryRecord(
      {
        sourcePath: "/tmp/meeting.m4a",
        provider: "assemblyai",
        options: { diarize: true, identify: true, model: "universal" },
        durationMinutes: 12,
        transcriptText: "Hello. Hi there.",
        segments: [
          { start: 0, end: 1, text: "Hello.", speaker: "Freya Wu" },
          { start: 1, end: 2, text: "Hi there.", speaker: "Speaker 2" },
          { start: 2, end: 3, text: "More words.", speaker: "Speaker 2" },
        ],
        outputPath: path.join(outputDir, "meeting.summary.md"),
        capturedAt: null,
        ...overrides,
      },
      historyDir,
    );
    return record.id;
  }

  it("renames the label in every segment and bumps updatedAt", async () => {
    const id = await makeRecord();
    const before = await loadHistoryRecord(id, historyDir);

    const result = await renameRecordSpeaker(id, "Speaker 2", "Kenny Kim", historyDir);
    expect(result.segmentsRenamed).toBe(2);

    const after = await loadHistoryRecord(id, historyDir);
    expect(after.segments.map((s) => s.speaker)).toEqual([
      "Freya Wu",
      "Kenny Kim",
      "Kenny Kim",
    ]);
    expect(after.updatedAt >= before.updatedAt).toBe(true);
  });

  it("renames the stored clip file and its map entry", async () => {
    const id = await makeRecord();
    await writeSpeakerClip(id, "Speaker 2", new Int16Array([1, 2, 3]), historyDir);
    // createHistoryRecord doesn't know about clips written after the fact —
    // patch the record the way the pipeline does.
    const recordPath = path.join(historyDir, `${id}.json`);
    const raw = JSON.parse(await readFile(recordPath, "utf-8"));
    raw.speakerClips = { "Speaker 2": `${id}.assets/Speaker 2.pcm` };
    await writeFile(recordPath, JSON.stringify(raw));

    const result = await renameRecordSpeaker(id, "Speaker 2", "Kenny Kim", historyDir);
    expect(result.clipRenamed).toBe(true);

    const after = await loadHistoryRecord(id, historyDir);
    expect(after.speakerClips).toEqual({
      "Kenny Kim": `${id}.assets/Kenny Kim.pcm`,
    });
    expect(await exists(speakerClipPath(id, "Kenny Kim", historyDir))).toBe(true);
    expect(await exists(speakerClipPath(id, "Speaker 2", historyDir))).toBe(false);
  });

  it("rewrites transcript lines in the output markdown", async () => {
    const id = await makeRecord();
    const record = await loadHistoryRecord(id, historyDir);
    const md = [
      "# Meeting",
      "",
      "## Full Transcript",
      "",
      "[00:00] **Freya Wu:** Hello.",
      "[00:01] **Speaker 2:** Hi there.",
      "Narrative mentioning Speaker 2 stays untouched outside bold labels? No —",
      "only the **Speaker 2:** pattern is rewritten.",
    ].join("\n");
    await writeFile(record.outputPath!, md, "utf-8");

    const result = await renameRecordSpeaker(id, "Speaker 2", "Kenny Kim", historyDir);
    expect(result.outputRewritten).toBe(true);

    const rewritten = await readFile(record.outputPath!, "utf-8");
    expect(rewritten).toContain("**Kenny Kim:** Hi there.");
    expect(rewritten).not.toContain("**Speaker 2:**");
    // Plain-prose mentions are not the transcript's label grammar; left alone.
    expect(rewritten).toContain("Narrative mentioning Speaker 2 stays");
  });

  it("survives a missing output file (record moved or deleted)", async () => {
    const id = await makeRecord({ outputPath: path.join(outputDir, "gone.md") });
    const result = await renameRecordSpeaker(id, "Speaker 2", "Kenny Kim", historyDir);
    expect(result.outputRewritten).toBe(false);
    const after = await loadHistoryRecord(id, historyDir);
    expect(after.segments[1].speaker).toBe("Kenny Kim");
  });

  it("merging into an existing name leaves the target clip alone", async () => {
    const id = await makeRecord();
    await writeSpeakerClip(id, "Speaker 2", new Int16Array([1, 1]), historyDir);
    await writeSpeakerClip(id, "Freya Wu", new Int16Array([2, 2]), historyDir);
    const recordPath = path.join(historyDir, `${id}.json`);
    const raw = JSON.parse(await readFile(recordPath, "utf-8"));
    raw.speakerClips = {
      "Speaker 2": `${id}.assets/Speaker 2.pcm`,
      "Freya Wu": `${id}.assets/Freya Wu.pcm`,
    };
    await writeFile(recordPath, JSON.stringify(raw));

    const result = await renameRecordSpeaker(id, "Speaker 2", "Freya Wu", historyDir);
    expect(result.clipRenamed).toBe(false);

    const after = await loadHistoryRecord(id, historyDir);
    // Target clip untouched; the orphaned source entry stays addressable.
    expect(after.speakerClips?.["Freya Wu"]).toBe(`${id}.assets/Freya Wu.pcm`);
    expect(after.speakerClips?.["Speaker 2"]).toBe(`${id}.assets/Speaker 2.pcm`);
    expect(after.segments.every((s) => s.speaker === "Freya Wu")).toBe(true);
  });

  it("refuses an unknown label", async () => {
    const id = await makeRecord();
    await expect(
      renameRecordSpeaker(id, "Speaker 9", "Kenny Kim", historyDir),
    ).rejects.toThrow(/Speaker 9/);
  });

  it("refuses an empty or identical name", async () => {
    const id = await makeRecord();
    await expect(
      renameRecordSpeaker(id, "Speaker 2", "  ", historyDir),
    ).rejects.toThrow(/empty/i);
    await expect(
      renameRecordSpeaker(id, "Speaker 2", "Speaker 2", historyDir),
    ).rejects.toThrow(/same/i);
  });

  it("resolves an id prefix like the other history verbs", async () => {
    const id = await makeRecord();
    const prefix = id.slice(0, 10);
    const result = await renameRecordSpeaker(prefix, "Speaker 2", "Kenny Kim", historyDir);
    expect(result.record.id).toBe(id);
  });
});
