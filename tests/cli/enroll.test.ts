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
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { enrollSpeaker, EnrollError } from "../../src/cli/enroll.js";
import type { SpeakerStore } from "../../src/pipeline/speakers.js";
import type { HistoryRecord } from "../../src/pipeline/history.js";

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const DUMMY_EMBEDDING = [0.1, 0.2, 0.3, 0.4];

function makeHistoryRecord(overrides: Partial<HistoryRecord> = {}): HistoryRecord {
  return {
    id: "20260101-000000Z-abc12345",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    capturedAt: "2026-01-01T00:00:00.000Z",
    sourcePath: "/tmp/nota-test-audio.mp3",
    sourceName: "nota-test-audio.mp3",
    provider: "assemblyai",
    options: {
      language: undefined,
      diarize: true,
      identify: false,
      model: "gpt-4o",
    },
    durationMinutes: 5,
    transcriptText: "[00:01] **Speaker 1:** Hello world.\n[00:03] **Speaker 2:** Hi there.",
    segments: [
      { speaker: "Speaker 1", text: "Hello world.", start: 1, end: 3 },
      { speaker: "Speaker 2", text: "Hi there.", start: 3, end: 5 },
      { speaker: "Speaker 1", text: "How are you?", start: 5, end: 7 },
    ],
    outputPath: "/tmp/nota-test-audio.summary.md",
    status: "completed",
    ...overrides,
  };
}

function writeStore(storePath: string, store: SpeakerStore): void {
  writeFileSync(storePath, JSON.stringify(store), "utf-8");
}

function readStore(storePath: string): SpeakerStore {
  return JSON.parse(readFileSync(storePath, "utf-8")) as SpeakerStore;
}

// ---------------------------------------------------------------------------
// Mock extractEmbeddings — set PYTHON_BIN to a small stub that returns JSON
// ---------------------------------------------------------------------------

// We mock the module so we don't need a real Python environment.
vi.mock("../../src/pipeline/speakers.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../src/pipeline/speakers.js")>();
  return {
    ...actual,
    extractEmbeddings: vi.fn(),
  };
});

// eslint-disable-next-line @typescript-eslint/consistent-type-imports
const speakersModule = await import("../../src/pipeline/speakers.js");
const mockExtractEmbeddings = speakersModule.extractEmbeddings as MockedFunction<
  typeof speakersModule.extractEmbeddings
>;

// ---------------------------------------------------------------------------
// Setup / teardown
// ---------------------------------------------------------------------------

let tempDir: string;
let historyDir: string;
let storePath: string;
let audioPath: string;
let stderrChunks: string[];
let stderrSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  tempDir = mkdtempSync(path.join(tmpdir(), "nota-enroll-test-"));
  historyDir = path.join(tempDir, "history");
  mkdirSync(historyDir, { recursive: true });
  storePath = path.join(tempDir, "speakers.json");

  // Create a dummy audio file so access() succeeds
  audioPath = path.join(tempDir, "audio.mp3");
  writeFileSync(audioPath, "fake-audio-data");

  stderrChunks = [];
  stderrSpy = vi
    .spyOn(process.stderr, "write")
    .mockImplementation((chunk: unknown) => {
      stderrChunks.push(typeof chunk === "string" ? chunk : String(chunk));
      return true;
    });

  // Default: extraction returns embedding for Speaker 1
  mockExtractEmbeddings.mockResolvedValue({ "Speaker 1": DUMMY_EMBEDDING });
});

afterEach(() => {
  stderrSpy.mockRestore();
  vi.clearAllMocks();
  rmSync(tempDir, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// Helper: write a history record to the temp history dir
// ---------------------------------------------------------------------------

function writeHistory(record: HistoryRecord): void {
  writeFileSync(
    path.join(historyDir, `${record.id}.json`),
    JSON.stringify(record),
    "utf-8",
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("enrollSpeaker – happy path", () => {
  it("creates a new speaker profile and appends a voiceprint", async () => {
    const record = makeHistoryRecord({ sourcePath: audioPath });
    writeHistory(record);
    writeStore(storePath, { version: 2, speakers: {} });

    await enrollSpeaker("20260101-000000Z-abc12345", "Speaker 1", "Alice", {
      storePath,
      historyDir,
    });

    const store = readStore(storePath);
    expect(store.speakers.Alice).toBeDefined();
    expect(store.speakers.Alice.voiceprints).toHaveLength(1);
    const vp = store.speakers.Alice.voiceprints[0];
    expect(vp.embedding).toEqual(DUMMY_EMBEDDING);
    expect(vp.source).toBe("audio.mp3");
    expect(vp.enrolledAt).toBeTruthy();
  });

  it("appends a voiceprint to an existing profile", async () => {
    const record = makeHistoryRecord({ sourcePath: audioPath });
    writeHistory(record);
    writeStore(storePath, {
      version: 2,
      speakers: {
        Alice: {
          voiceprints: [
            { id: "old", embedding: [1, 0], enrolledAt: "old", source: "old.mp3" },
          ],
        },
      },
    });

    await enrollSpeaker("20260101-000000Z-abc12345", "Speaker 1", "Alice", {
      storePath,
      historyDir,
    });

    const store = readStore(storePath);
    expect(store.speakers.Alice.voiceprints).toHaveLength(2);
    const newVp = store.speakers.Alice.voiceprints[1];
    expect(newVp.embedding).toEqual(DUMMY_EMBEDDING);
  });

  it("passes only the filtered segments to extractEmbeddings", async () => {
    const record = makeHistoryRecord({ sourcePath: audioPath });
    writeHistory(record);
    writeStore(storePath, { version: 2, speakers: {} });

    await enrollSpeaker("20260101-000000Z-abc12345", "Speaker 1", "Alice", {
      storePath,
      historyDir,
    });

    const [calledPath, calledSegments] = mockExtractEmbeddings.mock.calls[0];
    expect(calledPath).toBe(audioPath);
    // Only Speaker 1 segments (2 of them)
    expect(calledSegments.every((s) => s.speaker === "Speaker 1")).toBe(true);
    expect(calledSegments).toHaveLength(2);
  });

  it("prints a confirmation message to stderr", async () => {
    const record = makeHistoryRecord({ sourcePath: audioPath });
    writeHistory(record);
    writeStore(storePath, { version: 2, speakers: {} });

    await enrollSpeaker("20260101-000000Z-abc12345", "Speaker 1", "Alice", {
      storePath,
      historyDir,
    });

    expect(stderrChunks.join("")).toContain("Alice");
  });
});

describe("enrollSpeaker – missing history record (exit 2)", () => {
  it("throws EnrollError with exitCode 2 when id does not exist", async () => {
    writeStore(storePath, { version: 2, speakers: {} });

    await expect(
      enrollSpeaker("nonexistent-id", "Speaker 1", "Alice", {
        storePath,
        historyDir,
      }),
    ).rejects.toMatchObject({ exitCode: 2 });
  });
});

describe("enrollSpeaker – missing audio (exit 3)", () => {
  it("throws EnrollError with exitCode 3 when sourcePath does not exist", async () => {
    const record = makeHistoryRecord({ sourcePath: "/does/not/exist/audio.mp3" });
    writeHistory(record);
    writeStore(storePath, { version: 2, speakers: {} });

    await expect(
      enrollSpeaker("20260101-000000Z-abc12345", "Speaker 1", "Alice", {
        storePath,
        historyDir,
      }),
    ).rejects.toMatchObject({ exitCode: 3 });
  });
});

describe("enrollSpeaker – unknown speaker label (exit 1)", () => {
  it("throws EnrollError with exitCode 1 when label is not present in segments", async () => {
    const record = makeHistoryRecord({ sourcePath: audioPath });
    writeHistory(record);
    writeStore(storePath, { version: 2, speakers: {} });

    await expect(
      enrollSpeaker("20260101-000000Z-abc12345", "Speaker 99", "Alice", {
        storePath,
        historyDir,
      }),
    ).rejects.toMatchObject({ exitCode: 1 });
  });
});

describe("enrollSpeaker – pyannote unavailable (exit 4)", () => {
  it("throws EnrollError with exitCode 4 when extractEmbeddings fails with ENOENT", async () => {
    const record = makeHistoryRecord({ sourcePath: audioPath });
    writeHistory(record);
    writeStore(storePath, { version: 2, speakers: {} });

    mockExtractEmbeddings.mockRejectedValue(
      new Error("spawnSync python3 ENOENT"),
    );

    await expect(
      enrollSpeaker("20260101-000000Z-abc12345", "Speaker 1", "Alice", {
        storePath,
        historyDir,
      }),
    ).rejects.toMatchObject({ exitCode: 4 });
  });

  it("throws EnrollError with exitCode 4 when pyannote import fails", async () => {
    const record = makeHistoryRecord({ sourcePath: audioPath });
    writeHistory(record);
    writeStore(storePath, { version: 2, speakers: {} });

    mockExtractEmbeddings.mockRejectedValue(
      new Error("ModuleNotFoundError: No module named 'pyannote'"),
    );

    await expect(
      enrollSpeaker("20260101-000000Z-abc12345", "Speaker 1", "Alice", {
        storePath,
        historyDir,
      }),
    ).rejects.toMatchObject({ exitCode: 4 });
  });
});

describe("EnrollError", () => {
  it("is an instance of Error", () => {
    const e = new EnrollError("msg", 2);
    expect(e).toBeInstanceOf(Error);
    expect(e.exitCode).toBe(2);
    expect(e.message).toBe("msg");
  });
});
