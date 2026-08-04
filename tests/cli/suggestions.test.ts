import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
  type MockedFunction,
} from "vitest";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  acceptSuggestion,
  dismissSuggestion,
  listSuggestions,
  recomputeSuggestions,
} from "../../src/cli/suggestions.js";
import { EnrollError } from "../../src/cli/enroll.js";
import type { SpeakerStore } from "../../src/pipeline/speakers.js";
import type { HistoryRecord } from "../../src/pipeline/history.js";

// Partial mock: replace the ONNX entry points so tests run offline, but keep
// the real pure helpers (cosine, thresholds, InsufficientSpeechError) that
// speakers.ts and enroll.ts import.
vi.mock("../../src/pipeline/embed.js", async (importOriginal) => {
  const actual =
    await importOriginal<typeof import("../../src/pipeline/embed.js")>();
  return {
    ...actual,
    isIdentityAvailable: vi.fn(),
    computeEmbedding: vi.fn(),
    computeEmbeddings: vi.fn(),
  };
});

const embed = await import("../../src/pipeline/embed.js");
const mockIsIdentityAvailable = embed.isIdentityAvailable as MockedFunction<
  typeof embed.isIdentityAvailable
>;
const mockComputeEmbedding = embed.computeEmbedding as MockedFunction<
  typeof embed.computeEmbedding
>;
const mockComputeEmbeddings = embed.computeEmbeddings as MockedFunction<
  typeof embed.computeEmbeddings
>;

const SUGGESTION = {
  label: "Speaker 2",
  suggestedName: "Kenny Kim",
  score: 0.623,
  voiceprintId: "20260717-004104Z",
  state: "pending" as const,
};

function makeRecord(overrides: Partial<HistoryRecord> = {}): HistoryRecord {
  return {
    id: "20260803-185339Z-9575ad52",
    createdAt: "2026-08-03T18:53:39.000Z",
    updatedAt: "2026-08-03T18:53:39.000Z",
    capturedAt: "2026-08-03T18:53:39.000Z",
    sourcePath: "/tmp/nota-test-audio.mp3",
    sourceName: "nota-test-audio.mp3",
    provider: "assemblyai",
    options: { language: undefined, diarize: true, identify: true, model: "gpt-4o" },
    durationMinutes: 5,
    transcriptText: "hello",
    segments: [
      { speaker: "Speaker 1", text: "Hello world.", start: 1, end: 3 },
      { speaker: "Speaker 2", text: "Hi there.", start: 3, end: 5 },
    ],
    speakerClips: { "Speaker 2": "20260803-185339Z-9575ad52.assets/Speaker 2.pcm" },
    suggestions: [SUGGESTION],
    outputPath: "/tmp/nota-test-audio.summary.md",
    status: "completed",
    ...overrides,
  };
}

let tempDir: string;
let historyDir: string;
let storePath: string;
let stdoutChunks: string[];
let stderrChunks: string[];

function writeHistory(record: HistoryRecord): void {
  writeFileSync(path.join(historyDir, `${record.id}.json`), JSON.stringify(record), "utf-8");
}

function readRecord(id = "20260803-185339Z-9575ad52"): HistoryRecord {
  return JSON.parse(readFileSync(path.join(historyDir, `${id}.json`), "utf-8"));
}

function writeClip(record: HistoryRecord, label: string, bytes = 6): void {
  const rel = record.speakerClips![label];
  const abs = path.join(historyDir, rel);
  mkdirSync(path.dirname(abs), { recursive: true });
  writeFileSync(abs, Buffer.alloc(bytes));
}

function writeStore(store: SpeakerStore): void {
  writeFileSync(storePath, JSON.stringify(store), "utf-8");
}

beforeEach(() => {
  tempDir = mkdtempSync(path.join(tmpdir(), "nota-suggest-test-"));
  historyDir = path.join(tempDir, "history");
  mkdirSync(historyDir, { recursive: true });
  storePath = path.join(tempDir, "speakers.json");
  stdoutChunks = [];
  stderrChunks = [];
  vi.spyOn(process.stdout, "write").mockImplementation((chunk: unknown) => {
    stdoutChunks.push(typeof chunk === "string" ? chunk : String(chunk));
    return true;
  });
  vi.spyOn(process.stderr, "write").mockImplementation((chunk: unknown) => {
    stderrChunks.push(typeof chunk === "string" ? chunk : String(chunk));
    return true;
  });
  mockIsIdentityAvailable.mockResolvedValue(true);
  mockComputeEmbedding.mockResolvedValue(new Float32Array([0.6, 0.8]));
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.clearAllMocks();
  rmSync(tempDir, { recursive: true, force: true });
});

describe("listSuggestions", () => {
  it("prints pending suggestions as tab-separated rows, header on stderr", async () => {
    const decided = { ...SUGGESTION, label: "Speaker 1", state: "dismissed" as const };
    writeHistory(makeRecord({ suggestions: [SUGGESTION, decided] }));

    await listSuggestions({ historyDir });

    expect(stdoutChunks.join("")).toBe(
      "20260803-185339Z-9575ad52\tSpeaker 2\tKenny Kim\t0.623\n",
    );
    expect(stderrChunks.join("")).toContain("Record ID\tLabel\tSuggested name\tScore");
  });

  it("prints a no-pending notice on stderr when nothing is pending", async () => {
    await listSuggestions({ historyDir });
    expect(stdoutChunks.join("")).toBe("");
    expect(stderrChunks.join("")).toContain("No pending speaker suggestions.");
  });
});

describe("dismissSuggestion", () => {
  it("marks the suggestion dismissed with a decidedAt stamp, store untouched", async () => {
    writeHistory(makeRecord());

    await dismissSuggestion("20260803-185339Z-9575ad52", "Speaker 2", { historyDir });

    const record = readRecord();
    expect(record.suggestions![0].state).toBe("dismissed");
    expect(record.suggestions![0].decidedAt).toBeTruthy();
    expect(record.segments[1].speaker).toBe("Speaker 2"); // segments untouched
    expect(stderrChunks.join("")).toContain('Dismissed the suggestion for "Speaker 2"');
  });

  it("errors when no pending suggestion exists for the label", async () => {
    writeHistory(makeRecord({ suggestions: [] }));
    await expect(
      dismissSuggestion("20260803-185339Z-9575ad52", "Speaker 2", { historyDir }),
    ).rejects.toThrow(/No pending suggestion for label "Speaker 2"/);
  });
});

describe("acceptSuggestion", () => {
  it("enrolls the clip, renames the label, and marks the suggestion accepted", async () => {
    const record = makeRecord();
    writeHistory(record);
    writeClip(record, "Speaker 2");
    writeStore({ version: 4, speakers: {} });

    await acceptSuggestion("20260803-185339Z-9575ad52", "Speaker 2", {
      historyDir,
      storePath,
    });

    // Store: a Kenny Kim voiceprint from the record's clip.
    const store = JSON.parse(readFileSync(storePath, "utf-8")) as SpeakerStore;
    expect(store.speakers["Kenny Kim"].voiceprints).toHaveLength(1);
    expect(store.speakers["Kenny Kim"].voiceprints[0].source).toBe("nota-test-audio.mp3");

    // Record: segments renamed, suggestion accepted.
    const updated = readRecord();
    expect(updated.segments[1].speaker).toBe("Kenny Kim");
    expect(updated.suggestions![0].state).toBe("accepted");
    expect(stderrChunks.join("")).toContain('Accepted "Kenny Kim" for "Speaker 2"');
  });

  it("aborts with the enroll exit code when the clip is missing — nothing changes", async () => {
    writeHistory(makeRecord()); // no writeClip
    writeStore({ version: 4, speakers: {} });

    const promise = acceptSuggestion("20260803-185339Z-9575ad52", "Speaker 2", {
      historyDir,
      storePath,
    });
    await expect(promise).rejects.toMatchObject({ exitCode: 3 });

    const record = readRecord();
    expect(record.segments[1].speaker).toBe("Speaker 2");
    expect(record.suggestions![0].state).toBe("pending");
  });

  it("aborts with exit 4 when ONNX identity is unavailable", async () => {
    const record = makeRecord();
    writeHistory(record);
    writeClip(record, "Speaker 2");
    writeStore({ version: 4, speakers: {} });
    mockIsIdentityAvailable.mockResolvedValueOnce(false);

    await expect(
      acceptSuggestion("20260803-185339Z-9575ad52", "Speaker 2", { historyDir, storePath }),
    ).rejects.toMatchObject({ exitCode: 4 });
  });

  it("exits 2 for a missing record and 1 for a label with no pending suggestion", async () => {
    await expect(
      acceptSuggestion("nope-000000Z-00000000", "Speaker 2", { historyDir, storePath }),
    ).rejects.toMatchObject({ exitCode: 2 });

    writeHistory(makeRecord({ suggestions: [] }));
    await expect(
      acceptSuggestion("20260803-185339Z-9575ad52", "Speaker 2", { historyDir, storePath }),
    ).rejects.toMatchObject({ exitCode: 1 });
  });
});

describe("recomputeSuggestions", () => {
  it("recomputes from stored clips against the current store and replaces suggestions", async () => {
    const record = makeRecord({ suggestions: [] });
    writeHistory(record);
    writeClip(record, "Speaker 2");
    writeStore({
      version: 4,
      speakers: {
        "Kenny Kim": {
          voiceprints: [
            { id: "20260717-004104Z", embedding: [0.6, 0.8], enrolledAt: "t", source: "a.m4a" },
          ],
        },
      },
    });
    // Clip is tiny (6 bytes) — kaldiFbank would yield no frames, but the mock
    // replaces the embedding step entirely. The embedding is Kenny's voiceprint
    // rotated by ~53°: unit length, cosine 0.6018 — inside the tentative band.
    mockComputeEmbeddings.mockResolvedValue({ "Speaker 2": [-0.2778, 0.9606] });

    await recomputeSuggestions("20260803-185339Z-9575ad52", { historyDir, storePath });

    const updated = readRecord();
    expect(updated.suggestions!).toHaveLength(1);
    expect(updated.suggestions![0]).toMatchObject({
      label: "Speaker 2",
      suggestedName: "Kenny Kim",
      voiceprintId: "20260717-004104Z",
      state: "pending",
    });
    expect(updated.suggestions![0].score).toBeCloseTo(0.6018, 3);
    expect(stderrChunks.join("")).toContain(
      "Recomputed 1 suggestion(s) for history",
    );
  });

  it("exits 3 when the record has no stored clips", async () => {
    writeHistory(makeRecord({ speakerClips: {} }));
    await expect(
      recomputeSuggestions("20260803-185339Z-9575ad52", { historyDir, storePath }),
    ).rejects.toMatchObject({ exitCode: 3 });
  });

  it("exits 4 when ONNX identity is unavailable", async () => {
    const record = makeRecord();
    writeHistory(record);
    writeClip(record, "Speaker 2");
    writeStore({ version: 4, speakers: {} });
    mockIsIdentityAvailable.mockResolvedValueOnce(false);

    await expect(
      recomputeSuggestions("20260803-185339Z-9575ad52", { historyDir, storePath }),
    ).rejects.toMatchObject({ exitCode: 4 });
  });

  it("exits 2 for a missing record", async () => {
    await expect(
      recomputeSuggestions("nope-000000Z-00000000", { historyDir, storePath }),
    ).rejects.toMatchObject({ exitCode: 2 });
  });
});

describe("EnrollError propagation", () => {
  it("acceptSuggestion throws EnrollError instances the CLI maps to exit codes", async () => {
    await expect(
      acceptSuggestion("nope-000000Z-00000000", "Speaker 2", { historyDir, storePath }),
    ).rejects.toBeInstanceOf(EnrollError);
  });
});
