import { describe, expect, it, beforeEach, afterEach } from "vitest";
import { mkdtemp, rm, readFile, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  describeHistoryStatus,
  normalizeHistoryStatus,
  HISTORY_STATUSES,
  isInFlight,
  resolveInterrupted,
  canAdvance,
} from "../../src/pipeline/history-status.js";
import {
  historyStatusLabel,
  formatHistoryList,
  loadHistoryRecord,
  setRecordSummary,
  completeHistoryRecord,
  setRecordTags,
  applyEnrichmentToRecord,
  renameRecordSpeaker,
  setSuggestionState,
  type HistoryRecord,
} from "../../src/pipeline/history.js";

/**
 * XIA-447 — a paused live session, from the CLI's side of the contract.
 *
 * The decision the whole ticket turns on is that `paused` is a **flag beside
 * `status`**, never a status of its own. `macos/Nota/App/LiveSessionPersistence
 * .swift` writes it and `macos/Nota/App/HistoryStatus.swift`'s
 * `presentation(interrupted:paused:)` is the twin of `describeHistoryStatus`
 * here; these tests hold the half of that agreement the CLI owes.
 */
describe("a paused live session, in the record", () => {
  it("is a flag on `recording` and not a status in the vocabulary", () => {
    expect(HISTORY_STATUSES).not.toContain("paused");
    // …and that is a safety property, not tidiness: an unrecognized status
    // resolves by what the record HAS, and with no summary that is
    // `transcribed` — a REST state. `isInFlight` is false for it, so the launch
    // sweep would never revisit a paused session whose process went away, and
    // it would sit there forever as a finished transcript with no transcript.
    expect(normalizeHistoryStatus("paused", { hasSummary: false })).toBe("transcribed");
    expect(isInFlight("transcribed")).toBe(false);
    // The flag costs the machine nothing, because the status never moved.
    expect(isInFlight("recording")).toBe(true);
    expect(resolveInterrupted("recording")).toBe("failed:recording");
    expect(canAdvance("recording", "transcribing")).toBe(true);
  });

  it("reads as Paused, and only on a record that is recording", () => {
    expect(describeHistoryStatus("recording", { paused: true })).toBe("Paused");
    expect(describeHistoryStatus("recording", {})).toBe("Recording");
    expect(describeHistoryStatus("recording")).toBe("Recording");
    // A stale flag on any other status is stale, not a new state.
    expect(describeHistoryStatus("transcribing", { paused: true })).toBe("Transcribing");
    expect(describeHistoryStatus("done", { paused: true })).toBe("Done");
  });

  it("still reads as Interrupted when the process went away", () => {
    // The launch sweep is untouched by the flag: the record says `recording`,
    // so it resolves to failed(recording) + interrupted, and the words follow
    // what happened. Nobody is coming back to that session, so it is not still
    // paused.
    expect(
      describeHistoryStatus("failed:recording", { interrupted: true, paused: true }),
    ).toBe("Interrupted");
    expect(describeHistoryStatus("failed:recording", { paused: true })).toBe(
      "Failed (recording)",
    );
  });

  it("reaches `nota history list` and `nota history show` through one label", () => {
    const record = {
      id: "abc",
      createdAt: "2026-08-12T10:00:00.000Z",
      provider: "assemblyai",
      status: "recording",
      sourceName: "meeting.caf",
      paused: true,
    } as unknown as HistoryRecord;
    expect(historyStatusLabel(record)).toBe("Paused");
    // The raw `status` column is what scripts match on and it must NOT move —
    // that is the field the two implementations agree about.
    const list = formatHistoryList([record]);
    expect(list).toContain("\trecording\t");
    expect(list.trimEnd().endsWith("Paused")).toBe(true);

    expect(historyStatusLabel({ ...record, paused: false })).toBe("Recording");
    expect(historyStatusLabel({ ...record, paused: undefined })).toBe("Recording");
  });
});

/**
 * The other half of the deal `pinned` and `markers` already have: the CLI never
 * writes this field, so it survives only because every TS write path rebuilds
 * through `{ ...record }`. Driven rather than asserted about the spread, so a
 * writer that stops merging fails loudly instead of drifting.
 */
describe("the app's paused flag survives the CLI's write paths", () => {
  let historyDir: string;

  beforeEach(async () => {
    historyDir = await mkdtemp(path.join(tmpdir(), "nota-paused-"));
  });

  afterEach(async () => {
    await rm(historyDir, { recursive: true, force: true });
  });

  async function seed(overrides: Record<string, unknown> = {}): Promise<string> {
    const id = "rec-paused";
    await mkdir(historyDir, { recursive: true });
    const record = {
      id,
      createdAt: "2026-08-12T10:00:00.000Z",
      provider: "assemblyai",
      transcriptionModel: "universal",
      summaryModel: "gpt-5-mini",
      sourceName: "meeting.caf",
      sourcePath: "/tmp/meeting.caf",
      status: "transcribed",
      transcript: "hello",
      paused: true,
      pinned: true,
      markers: [{ atSeconds: 12 }],
      ...overrides,
    };
    await writeFile(
      path.join(historyDir, `${id}.json`),
      JSON.stringify(record, null, 2),
      "utf-8",
    );
    return id;
  }

  it("is carried across a read", async () => {
    const id = await seed();
    const record = await loadHistoryRecord(id, historyDir);
    expect(record?.paused).toBe(true);
  });

  /**
   * **Every writer, not one.** The predecessor drove `setRecordSummary` alone
   * while its docstring claimed to hold the whole deal — so a rewrite of
   * `applyEnrichmentToRecord` (or any of the other five) that built a fresh
   * object from named fields would drop `paused`, `pinned` and `markers`
   * silently with this suite green.
   */
  const writers: Array<{
    name: string;
    seed?: Record<string, unknown>;
    run: (id: string, dir: string) => Promise<unknown>;
  }> = [
    {
      name: "completeHistoryRecord",
      run: (id, dir) =>
        completeHistoryRecord(
          id,
          { summary: summaryFixture(), outputPath: "/tmp/out.md" },
          dir,
        ),
    },
    {
      name: "setRecordSummary",
      run: (id, dir) => setRecordSummary(id, { summary: summaryFixture() }, dir),
    },
    {
      name: "setRecordTags",
      run: (id, dir) => setRecordTags(id, { tags: ["one"] }, dir),
    },
    {
      name: "applyEnrichmentToRecord",
      run: (id, dir) => applyEnrichmentToRecord(id, { tags: ["two"] }, dir),
    },
    {
      name: "renameRecordSpeaker",
      seed: {
        segments: [{ start: 0, end: 1, text: "hi", speaker: "Speaker 1" }],
      },
      run: (id, dir) => renameRecordSpeaker(id, "Speaker 1", "Kenny Kim", dir),
    },
    {
      name: "setSuggestionState",
      seed: {
        suggestions: [
          {
            label: "Speaker 1",
            suggestedName: "Kenny Kim",
            score: 0.62,
            voiceprintId: "vp-1",
            state: "pending",
          },
        ],
      },
      run: (id, dir) => setSuggestionState(id, "Speaker 1", "dismissed", dir),
    },
  ];

  function summaryFixture() {
    return {
      narrative: "a summary",
      topics: [],
      decisions: [],
      actionItems: [],
    };
  }

  it("is carried across a read", async () => {
    const id = await seed();
    const record = await loadHistoryRecord(id, historyDir);
    expect(record?.paused).toBe(true);
  });

  for (const writer of writers) {
    it(`is carried across ${writer.name}`, async () => {
      const id = await seed(writer.seed);
      await writer.run(id, historyDir);
      const raw = JSON.parse(
        await readFile(path.join(historyDir, `${id}.json`), "utf-8"),
      );
      expect(raw.paused).toBe(true);
      // …and it is a merge, not a lucky field order: the neighbours the same
      // rule protects come through too.
      expect(raw.pinned).toBe(true);
      expect(raw.markers).toEqual([{ atSeconds: 12 }]);
    });
  }
});
