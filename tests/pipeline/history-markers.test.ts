/**
 * The `markers` field (XIA-433) is written by the **macOS app** and by nothing
 * in TypeScript — the same deal `pinned` has. What the CLI owes it is survival:
 * every verb that rewrites `<id>.json` rebuilds through `{ ...record }`, so an
 * unknown key comes across. That is a property of a spread, and a property of a
 * spread is exactly the kind of thing a refactor removes without noticing, so
 * it is pinned here rather than asserted in a comment.
 *
 * The key names are half the contract: Swift writes `atSeconds`, not `at`
 * (`LiveSessionPersistence.markerDictionaries`), and an unlabelled marker
 * carries no `label` key at all rather than a null.
 */
import { mkdtemp, rm, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  applyEnrichmentToRecord,
  loadHistoryRecord,
  renameRecordSpeaker,
  setRecordSummary,
  setRecordTags,
  setSuggestionState,
} from "../../src/pipeline/history.js";
import { deleteRecordAudio } from "../../src/pipeline/storage.js";
import type { HistoryMarker, HistoryRecord } from "../../src/pipeline/history.js";

/** Byte-for-byte what the app writes: two moments, one of them labelled. */
const MARKERS: HistoryMarker[] = [
  {
    id: "6E4B0E9A-0000-4000-8000-000000000001",
    atSeconds: 12.5,
    createdAt: "2026-08-11T10:00:12.500Z",
  },
  {
    id: "6E4B0E9A-0000-4000-8000-000000000002",
    atSeconds: 44,
    createdAt: "2026-08-11T10:00:44.000Z",
    label: "Rollback note",
  },
];

describe("history markers survive every TS write path", () => {
  let historyDir: string;
  let id: string;

  const record = async (): Promise<HistoryRecord> =>
    loadHistoryRecord(id, historyDir);

  const markers = async (): Promise<HistoryMarker[] | undefined> =>
    (await record()).markers;

  beforeEach(async () => {
    historyDir = await mkdtemp(path.join(tmpdir(), "nota-markers-test-"));
    id = "20260811-100000-abcd1234";
    const seed = {
      id,
      createdAt: "2026-08-11T10:00:00.000Z",
      updatedAt: "2026-08-11T10:00:00.000Z",
      sourcePath: "/tmp/meeting.m4a",
      sourceName: "meeting.m4a",
      provider: "assemblyai",
      options: { diarize: true, identify: false, model: "gpt-5-mini" },
      durationMinutes: 2,
      transcriptText: "hello",
      segments: [{ start: 0, end: 60, text: "hello", speaker: "Speaker 1" }],
      outputPath: path.join(historyDir, "meeting.summary.md"),
      status: "transcribed",
      suggestions: [
        {
          label: "Speaker 1",
          suggestedName: "Kenny Kim",
          score: 0.62,
          voiceprintId: "vp-1",
          state: "pending",
        },
      ],
      markers: MARKERS,
    };
    await writeFile(
      path.join(historyDir, `${id}.json`),
      JSON.stringify(seed, null, 2),
      "utf-8",
    );
  });

  afterEach(async () => {
    await rm(historyDir, { recursive: true, force: true });
  });

  it("reads the app's markers back field for field", async () => {
    expect(await markers()).toEqual(MARKERS);
    // The key names, spelled out: `atSeconds` is what Swift writes, and an
    // unlabelled marker has no `label` key rather than a null one.
    const raw = JSON.parse(
      await readFile(path.join(historyDir, `${id}.json`), "utf-8"),
    );
    expect(Object.keys(raw.markers[0]).sort()).toEqual([
      "atSeconds",
      "createdAt",
      "id",
    ]);
    expect(raw.markers[1].label).toBe("Rollback note");
  });

  it("keeps them through the summary the app's own Stop runs", async () => {
    await setRecordSummary(
      id,
      {
        summary: {
          title: "Sync",
          tags: ["sync"],
          narrative: "A short meeting.",
          keyTopics: [],
          decisions: [],
          actionItems: [],
        },
      },
      historyDir,
    );
    expect(await markers()).toEqual(MARKERS);
    expect((await record()).status).toBe("done");
  });

  it("keeps them through tags, enrichment, a rename and a suggestion decision", async () => {
    await setRecordTags(id, { tags: ["planning"] }, historyDir);
    expect(await markers()).toEqual(MARKERS);

    await applyEnrichmentToRecord(id, { summary: "Enriched." }, historyDir);
    expect(await markers()).toEqual(MARKERS);

    await renameRecordSpeaker(id, "Speaker 1", "Kenny Kim", historyDir);
    expect(await markers()).toEqual(MARKERS);

    await setSuggestionState(id, "Speaker 1", "dismissed", historyDir);
    expect(await markers()).toEqual(MARKERS);
  });

  it("keeps them when the audio is deleted — a record without audio is still a record", async () => {
    await deleteRecordAudio(id, historyDir);
    expect(await markers()).toEqual(MARKERS);
  });
});
