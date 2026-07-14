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

// Mock the ONNX wrapper so tests run offline without downloading the model.
// InsufficientSpeechError is a real class so enroll.ts `instanceof` works.
vi.mock("../../src/pipeline/embed.js", () => {
  class InsufficientSpeechError extends Error {
    constructor() {
      super("Not enough speech to compute a speaker embedding");
      this.name = "InsufficientSpeechError";
    }
  }
  return {
    isIdentityAvailable: vi.fn(),
    computeEmbedding: vi.fn(),
    InsufficientSpeechError,
  };
});

const embed = await import("../../src/pipeline/embed.js");
const mockIsIdentityAvailable = embed.isIdentityAvailable as MockedFunction<
  typeof embed.isIdentityAvailable
>;
const mockComputeEmbedding = embed.computeEmbedding as MockedFunction<
  typeof embed.computeEmbedding
>;
const { InsufficientSpeechError } = embed;

function makeHistoryRecord(overrides: Partial<HistoryRecord> = {}): HistoryRecord {
  return {
    id: "20260101-000000Z-abc12345",
    createdAt: "2026-01-01T00:00:00.000Z",
    updatedAt: "2026-01-01T00:00:00.000Z",
    capturedAt: "2026-01-01T00:00:00.000Z",
    sourcePath: "/tmp/nota-test-audio.mp3",
    sourceName: "nota-test-audio.mp3",
    provider: "assemblyai",
    options: { language: undefined, diarize: true, identify: true, model: "gpt-4o" },
    durationMinutes: 5,
    transcriptText: "hello",
    segments: [{ speaker: "Speaker 1", text: "Hello world.", start: 1, end: 3 }],
    speakerClips: { "Speaker 1": "20260101-000000Z-abc12345.assets/Speaker 1.pcm" },
    outputPath: "/tmp/nota-test-audio.summary.md",
    status: "completed",
    ...overrides,
  };
}

let tempDir: string;
let historyDir: string;
let storePath: string;
let stderrSpy: ReturnType<typeof vi.spyOn>;

function writeHistory(record: HistoryRecord): void {
  writeFileSync(path.join(historyDir, `${record.id}.json`), JSON.stringify(record), "utf-8");
}

/** Write a stored PCM clip for the given label at the path enroll expects. */
function writeClip(record: HistoryRecord, label: string, bytes = 6): void {
  const rel = record.speakerClips![label];
  const abs = path.join(historyDir, rel);
  mkdirSync(path.dirname(abs), { recursive: true });
  writeFileSync(abs, Buffer.alloc(bytes)); // even length → whole Int16 samples
}

function writeStore(store: SpeakerStore): void {
  writeFileSync(storePath, JSON.stringify(store), "utf-8");
}
function readStore(): SpeakerStore {
  return JSON.parse(readFileSync(storePath, "utf-8")) as SpeakerStore;
}

beforeEach(() => {
  tempDir = mkdtempSync(path.join(tmpdir(), "nota-enroll-test-"));
  historyDir = path.join(tempDir, "history");
  mkdirSync(historyDir, { recursive: true });
  storePath = path.join(tempDir, "speakers.json");
  stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
  mockIsIdentityAvailable.mockResolvedValue(true);
  mockComputeEmbedding.mockResolvedValue(new Float32Array([0.6, 0.8]));
});

afterEach(() => {
  stderrSpy.mockRestore();
  vi.clearAllMocks();
  rmSync(tempDir, { recursive: true, force: true });
});

describe("enrollSpeaker – happy path", () => {
  it("creates a profile and stores the ONNX embedding voiceprint", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({ version: 4, speakers: {} });

    await enrollSpeaker(record.id, "Speaker 1", "Alice", {
      storePath,
      historyDir,
    });

    const store = readStore();
    expect(store.speakers.Alice.voiceprints).toHaveLength(1);
    const vp = store.speakers.Alice.voiceprints[0];
    expect(vp.embedding).toEqual([0.6000000238418579, 0.800000011920929]);
    expect(vp.source).toBe("nota-test-audio.mp3");
  });

  it("appends to an existing profile", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({
      version: 4,
      speakers: {
        Alice: { voiceprints: [{ id: "old", embedding: [1, 0], enrolledAt: "old", source: "o.m4a" }] },
      },
    });

    await enrollSpeaker(record.id, "Speaker 1", "Alice", {
      storePath,
      historyDir,
    });

    expect(readStore().speakers.Alice.voiceprints).toHaveLength(2);
  });
});

describe("enrollSpeaker – error exit codes", () => {
  it("exit 4 with actionable guidance when ONNX identity is unavailable", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({ version: 4, speakers: {} });
    mockIsIdentityAvailable.mockResolvedValueOnce(false);

    const promise = enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir });
    await expect(promise).rejects.toMatchObject({ exitCode: 4 });
    await expect(promise).rejects.toThrow(/model download.*onnxruntime-node/i);
  });

  it("exit 2 when the history record does not exist", async () => {
    writeStore({ version: 4, speakers: {} });
    await expect(
      enrollSpeaker("nonexistent-id", "Speaker 1", "Alice", { storePath, historyDir }),
    ).rejects.toMatchObject({ exitCode: 2 });
  });

  it("exit 3 when the speaker has no stored clip", async () => {
    const record = makeHistoryRecord({ speakerClips: {} });
    writeHistory(record);
    writeStore({ version: 4, speakers: {} });
    await expect(
      enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir }),
    ).rejects.toMatchObject({ exitCode: 3 });
  });

  it("exit 3 when the clip pointer exists but the file is missing", async () => {
    const record = makeHistoryRecord();
    writeHistory(record); // note: no writeClip — file absent
    writeStore({ version: 4, speakers: {} });
    await expect(
      enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir }),
    ).rejects.toMatchObject({ exitCode: 3 });
  });

  it("exit 5 when there is insufficient speech to enroll", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({ version: 4, speakers: {} });
    mockComputeEmbedding.mockRejectedValueOnce(new InsufficientSpeechError());

    await expect(
      enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir }),
    ).rejects.toMatchObject({ exitCode: 5 });
  });

  it("exit 1 on any other ONNX failure", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({ version: 4, speakers: {} });
    mockComputeEmbedding.mockRejectedValueOnce(new Error("boom"));

    await expect(
      enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir }),
    ).rejects.toMatchObject({ exitCode: 1 });
  });
});

describe("EnrollError", () => {
  it("is an instance of Error and carries an exit code", () => {
    const e = new EnrollError("msg", 2);
    expect(e).toBeInstanceOf(Error);
    expect(e.exitCode).toBe(2);
    expect(e.message).toBe("msg");
  });
});
