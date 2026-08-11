import { describe, expect, it } from "vitest";
import { mkdtemp, mkdir, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  HISTORY_STATUSES,
  canAdvance,
  canCompleteWithSummary,
  describeHistoryStatus,
  failedStatus,
  failureStage,
  isInFlight,
  isTerminal,
  normalizeHistoryStatus,
  resolveInterrupted,
  type HistoryStatus,
} from "../../src/pipeline/history-status.js";
import {
  applyEnrichmentToRecord,
  formatHistoryList,
  historyStatusLabel,
  loadHistoryRecord,
  recordAudioPath,
  setRecordSummary,
} from "../../src/pipeline/history.js";

async function tempHistoryDir(): Promise<string> {
  return mkdtemp(path.join(tmpdir(), "nota-history-status-"));
}

describe("history status state machine", () => {
  it("names a failure with the stage it happened in", () => {
    expect(failedStatus("transcribing")).toBe("failed:transcribing");
    expect(failureStage("failed:summarizing")).toBe("summarizing");
    expect(failureStage("done")).toBeNull();
    expect(failureStage("transcribed")).toBeNull();
  });

  it("separates the stages a process is working from the ones it is not", () => {
    expect(isInFlight("recording")).toBe(true);
    expect(isInFlight("transcribing")).toBe(true);
    expect(isInFlight("summarizing")).toBe(true);
    // `transcribed` is a rest state: nobody is working, and nothing is wrong.
    expect(isInFlight("transcribed")).toBe(false);
    expect(isInFlight("done")).toBe(false);
    expect(isInFlight("failed:recording")).toBe(false);
  });

  it("calls done and every failure terminal, and nothing else", () => {
    const terminal = HISTORY_STATUSES.filter(isTerminal);
    expect([...terminal].sort()).toEqual(
      [
        "done",
        "failed:recording",
        "failed:summarizing",
        "failed:transcribing",
      ].sort(),
    );
  });

  it("walks the happy path one step at a time", () => {
    expect(canAdvance("recording", "transcribing")).toBe(true);
    expect(canAdvance("transcribing", "transcribed")).toBe(true);
    expect(canAdvance("transcribed", "summarizing")).toBe(true);
    expect(canAdvance("summarizing", "done")).toBe(true);
    // The transcript-only meeting path skips the rest state.
    expect(canAdvance("transcribing", "summarizing")).toBe(true);
  });

  it("refuses to skip stages, go backwards, or leave a terminal status", () => {
    expect(canAdvance("recording", "done")).toBe(false);
    expect(canAdvance("recording", "summarizing")).toBe(false);
    expect(canAdvance("summarizing", "transcribing")).toBe(false);
    expect(canAdvance("done", "summarizing")).toBe(false);
    expect(canAdvance("failed:recording", "transcribing")).toBe(false);
    expect(canAdvance("done", "done")).toBe(false);
  });

  it("lets a record fail only in the stage it is actually in", () => {
    expect(canAdvance("recording", "failed:recording")).toBe(true);
    expect(canAdvance("transcribing", "failed:transcribing")).toBe(true);
    expect(canAdvance("summarizing", "failed:summarizing")).toBe(true);
    // Waiting for a summary, so the summary is what can fail.
    expect(canAdvance("transcribed", "failed:summarizing")).toBe(true);
    expect(canAdvance("transcribed", "failed:recording")).toBe(false);
    expect(canAdvance("recording", "failed:summarizing")).toBe(false);
  });

  it("resolves an interrupted record to the failure of its own stage", () => {
    expect(resolveInterrupted("recording")).toBe("failed:recording");
    expect(resolveInterrupted("transcribing")).toBe("failed:transcribing");
    expect(resolveInterrupted("summarizing")).toBe("failed:summarizing");
    // Nothing was in flight, so nothing was interrupted.
    expect(resolveInterrupted("transcribed")).toBeNull();
    expect(resolveInterrupted("done")).toBeNull();
    expect(resolveInterrupted("failed:recording")).toBeNull();
  });

  it("presents an interrupted failure as Interrupted, not as a failed stage", () => {
    expect(
      describeHistoryStatus("failed:recording", { interrupted: true }),
    ).toBe("Interrupted");
    expect(describeHistoryStatus("failed:recording")).toBe("Failed (recording)");
    expect(describeHistoryStatus("recording")).toBe("Recording");
    expect(describeHistoryStatus("done")).toBe("Done");
  });
});

describe("tolerant decode of a legacy record", () => {
  it("maps the legacy completed spelling to done", () => {
    expect(normalizeHistoryStatus("completed", { hasSummary: true })).toBe(
      "done",
    );
  });

  it("keeps transcribed, which meant then what it means now", () => {
    expect(normalizeHistoryStatus("transcribed", { hasSummary: false })).toBe(
      "transcribed",
    );
  });

  it("resolves an absent or unknown status by what the record has", () => {
    expect(normalizeHistoryStatus(undefined, { hasSummary: true })).toBe("done");
    expect(normalizeHistoryStatus(undefined, { hasSummary: false })).toBe(
      "transcribed",
    );
    expect(normalizeHistoryStatus("archived", { hasSummary: false })).toBe(
      "transcribed",
    );
    expect(normalizeHistoryStatus(42, { hasSummary: true })).toBe("done");
  });

  it("never resolves a legacy record into a live stage", () => {
    // A legacy record that decoded as in-flight would be swept up as
    // "Interrupted" at the next launch, on every machine, forever.
    for (const raw of [undefined, null, "", "completed", "transcribed", "??"]) {
      for (const hasSummary of [true, false]) {
        expect(isInFlight(normalizeHistoryStatus(raw, { hasSummary }))).toBe(
          false,
        );
      }
    }
  });

  it("loads a record written before this vocabulary existed", async () => {
    const historyDir = await tempHistoryDir();
    const id = "20260101-000000Z-abcdef01";
    // Byte-for-byte the shape a pre-XIA-430 Nota wrote: no audioPath, no
    // audioBytes, and "completed" where the status now says "done".
    await writeFile(
      path.join(historyDir, `${id}.json`),
      JSON.stringify({
        id,
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
        capturedAt: null,
        sourcePath: "/tmp/legacy.m4a",
        sourceName: "legacy.m4a",
        provider: "assemblyai",
        options: { diarize: false, identify: false, model: "gpt-5-mini" },
        durationMinutes: 3,
        transcriptText: "Hello.",
        segments: [],
        summary: { title: "Legacy", tags: [], narrative: "n" },
        outputPath: "/tmp/legacy.summary.md",
        status: "completed",
      }),
      "utf-8",
    );

    const record = await loadHistoryRecord(id, historyDir);
    expect(record.status).toBe<HistoryStatus>("done");
    expect(record.audioPath).toBeUndefined();
    // The record still resolves to its audio, through the absolute fallback.
    expect(recordAudioPath(record, historyDir)).toBe("/tmp/legacy.m4a");
  });

  it("does not rewrite the file just by reading it", async () => {
    const historyDir = await tempHistoryDir();
    const id = "20260101-000000Z-abcdef02";
    const file = path.join(historyDir, `${id}.json`);
    const original = JSON.stringify({
      id,
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
      capturedAt: null,
      sourcePath: "/tmp/legacy.m4a",
      sourceName: "legacy.m4a",
      provider: "assemblyai",
      options: { diarize: false, identify: false, model: "gpt-5-mini" },
      durationMinutes: 3,
      transcriptText: "Hello.",
      segments: [],
      status: "completed",
    });
    await writeFile(file, original, "utf-8");
    await loadHistoryRecord(id, historyDir);
    expect(await readFile(file, "utf-8")).toBe(original);
  });

  it("writes done, so the app and the CLI agree on the same word", async () => {
    const historyDir = await tempHistoryDir();
    const id = "20260101-000000Z-abcdef03";
    await writeFile(
      path.join(historyDir, `${id}.json`),
      JSON.stringify({
        id,
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
        capturedAt: null,
        sourcePath: "/tmp/a.m4a",
        sourceName: "a.m4a",
        provider: "assemblyai",
        options: { diarize: false, identify: false, model: "gpt-5-mini" },
        durationMinutes: 1,
        transcriptText: "Hi.",
        segments: [],
        status: "transcribed",
      }),
      "utf-8",
    );
    const updated = await setRecordSummary(
      id,
      {
        summary: {
          title: "T",
          tags: [],
          narrative: "n",
          keyTopics: [],
          decisions: [],
          actionItems: [],
        },
      },
      historyDir,
    );
    expect(updated.status).toBe<HistoryStatus>("done");
    const onDisk = JSON.parse(
      await readFile(path.join(historyDir, `${id}.json`), "utf-8"),
    );
    expect(onDisk.status).toBe("done");
  });
});

describe("the write path honors the machine", () => {
  const summary = {
    title: "T",
    tags: [] as string[],
    narrative: "n",
    keyTopics: [] as string[],
    decisions: [] as string[],
    actionItems: [] as string[],
  };

  async function writeRecord(
    historyDir: string,
    id: string,
    status: string,
  ): Promise<void> {
    await writeFile(
      path.join(historyDir, `${id}.json`),
      JSON.stringify({
        id,
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z",
        capturedAt: null,
        sourcePath: "/tmp/a.m4a",
        sourceName: "a.m4a",
        provider: "assemblyai",
        options: { diarize: false, identify: false, model: "gpt-5-mini" },
        durationMinutes: 1,
        transcriptText: "",
        segments: [],
        status,
      }),
      "utf-8",
    );
  }

  it("admits a summary only where one can honestly complete a record", () => {
    // The record has a transcript, or is being/has been summarized.
    expect(canCompleteWithSummary("transcribed")).toBe(true);
    expect(canCompleteWithSummary("summarizing")).toBe(true);
    // A regeneration (--force), and a retry of the one retryable stage.
    expect(canCompleteWithSummary("done")).toBe(true);
    expect(canCompleteWithSummary("failed:summarizing")).toBe(true);
    // Nothing to summarize: no transcript ever landed.
    expect(canCompleteWithSummary("recording")).toBe(false);
    expect(canCompleteWithSummary("failed:recording")).toBe(false);
    expect(canCompleteWithSummary("failed:transcribing")).toBe(false);
  });

  it("refuses to declare a live recording done", async () => {
    // `nota history summarize` used to write `done` over whatever it found —
    // including a session that was still recording, or one whose process went
    // away with no transcript in the record at all.
    const historyDir = await tempHistoryDir();
    const id = "20260101-000000Z-abcdef05";
    await writeRecord(historyDir, id, "recording");

    await expect(
      setRecordSummary(id, { summary }, historyDir),
    ).rejects.toThrow(/recording/);

    const onDisk = JSON.parse(
      await readFile(path.join(historyDir, `${id}.json`), "utf-8"),
    );
    expect(onDisk.status).toBe("recording");
    expect(onDisk.summary).toBeUndefined();
  });

  it("refuses a record whose transcription failed", async () => {
    const historyDir = await tempHistoryDir();
    const id = "20260101-000000Z-abcdef06";
    await writeRecord(historyDir, id, "failed:transcribing");
    await expect(
      setRecordSummary(id, { summary }, historyDir),
    ).rejects.toThrow(/failed:transcribing/);
  });

  it("still lets a failed summary be retried, on a record that has its transcript", async () => {
    const historyDir = await tempHistoryDir();
    const id = "20260101-000000Z-abcdef07";
    await writeRecord(historyDir, id, "failed:summarizing");
    const updated = await setRecordSummary(id, { summary }, historyDir);
    expect(updated.status).toBe<HistoryStatus>("done");
  });

  it("refuses a hand-applied enrichment on a live record too", async () => {
    const historyDir = await tempHistoryDir();
    const id = "20260101-000000Z-abcdef08";
    await writeRecord(historyDir, id, "recording");
    await expect(
      applyEnrichmentToRecord(id, { summary: "typed by hand" }, historyDir),
    ).rejects.toThrow(/recording/);
  });

  it("lets tags alone through, since they complete nothing", async () => {
    const historyDir = await tempHistoryDir();
    const id = "20260101-000000Z-abcdef09";
    await writeRecord(historyDir, id, "recording");
    const updated = await applyEnrichmentToRecord(
      id,
      { tags: ["standup"] },
      historyDir,
    );
    expect(updated.status).toBe<HistoryStatus>("recording");
  });
});

describe("the CLI prints the status the app displays", () => {
  const base = {
    id: "20260101-000000Z-abcdef10",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    capturedAt: null,
    sourcePath: "/tmp/a.m4a",
    sourceName: "a.m4a",
    provider: "assemblyai" as const,
    options: { diarize: false, identify: false, model: "gpt-5-mini" },
    durationMinutes: 1,
    transcriptText: "",
    segments: [],
  };

  it("words a record's state the way the app's own status line does", () => {
    expect(historyStatusLabel({ ...base, status: "recording" })).toBe(
      "Recording",
    );
    expect(historyStatusLabel({ ...base, status: "transcribed" })).toBe(
      "Transcribed",
    );
    expect(
      historyStatusLabel({ ...base, status: "failed:summarizing" }),
    ).toBe("Failed (summarizing)");
  });

  it("says Interrupted for a record the launch sweep resolved", () => {
    expect(
      historyStatusLabel({
        ...base,
        status: "failed:recording",
        interrupted: true,
      }),
    ).toBe("Interrupted");
  });

  it("carries that state into the list, next to the raw status scripts match on", () => {
    const list = formatHistoryList([
      { ...base, status: "failed:recording", interrupted: true },
    ]);
    expect(list).toContain("Created\tID\tProvider\tStatus\tSource\tState");
    expect(list).toContain("failed:recording\ta.m4a\tInterrupted");
  });
});

describe("relative audio path resolution", () => {
  const record = {
    id: "20260101-000000Z-abcdef04",
    audioPath: "recording.caf",
    sourcePath: "/somewhere/else/recording.caf",
  };

  it("resolves audioPath against the record's own assets folder", () => {
    expect(recordAudioPath(record, "/home/me/.nota/history")).toBe(
      "/home/me/.nota/history/20260101-000000Z-abcdef04.assets/recording.caf",
    );
  });

  it("follows the store wholesale, without the record being rewritten", () => {
    // The point of storing it relative: move ~/.nota and every record still
    // resolves, with not one byte of JSON changed.
    expect(recordAudioPath(record, "/Volumes/Archive/nota/history")).toBe(
      "/Volumes/Archive/nota/history/20260101-000000Z-abcdef04.assets/recording.caf",
    );
  });

  it("prefers the relative path over the stale absolute one", () => {
    expect(recordAudioPath(record, "/home/me/.nota/history")).not.toBe(
      record.sourcePath,
    );
  });

  it("falls back to sourcePath for a record that predates audioPath", () => {
    expect(
      recordAudioPath(
        { id: record.id, sourcePath: "/tmp/legacy.m4a" },
        "/home/me/.nota/history",
      ),
    ).toBe("/tmp/legacy.m4a");
    expect(
      recordAudioPath({ id: record.id, sourcePath: "" }, "/tmp"),
    ).toBeNull();
  });

  it("points at a file that is really there", async () => {
    const historyDir = await tempHistoryDir();
    const assets = path.join(historyDir, `${record.id}.assets`);
    await mkdir(assets, { recursive: true });
    await writeFile(path.join(assets, "recording.caf"), "audio", "utf-8");
    const resolved = recordAudioPath(record, historyDir)!;
    expect(await readFile(resolved, "utf-8")).toBe("audio");
  });
});
