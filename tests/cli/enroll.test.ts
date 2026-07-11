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
import { decodeProfile, type SpeakerStore } from "../../src/pipeline/speakers.js";
import type { HistoryRecord } from "../../src/pipeline/history.js";

const ACCESS_KEY = "pv-test-key";

// Mock the Eagle wrapper so tests run without a native engine or AccessKey.
// isEagleAvailable keeps its real (key-presence) semantics; enrollProfile is a
// spy; InsufficientSpeechError is a real class so enroll.ts `instanceof` works.
vi.mock("../../src/pipeline/eagle.js", () => {
  class InsufficientSpeechError extends Error {
    constructor() {
      super("Not enough speech to enroll a voice profile");
      this.name = "InsufficientSpeechError";
    }
  }
  return {
    isEagleAvailable: (k?: string) => Boolean(k && k.trim()),
    enrollProfile: vi.fn(),
    InsufficientSpeechError,
  };
});

const eagle = await import("../../src/pipeline/eagle.js");
const mockEnrollProfile = eagle.enrollProfile as MockedFunction<
  typeof eagle.enrollProfile
>;
const { InsufficientSpeechError } = eagle;

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
  mockEnrollProfile.mockResolvedValue(new Uint8Array([1, 2, 3, 4]));
});

afterEach(() => {
  stderrSpy.mockRestore();
  vi.clearAllMocks();
  rmSync(tempDir, { recursive: true, force: true });
});

describe("enrollSpeaker – happy path", () => {
  it("creates a profile and stores the base64 Eagle voiceprint", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({ version: 3, speakers: {} });

    await enrollSpeaker(record.id, "Speaker 1", "Alice", {
      storePath,
      historyDir,
      accessKey: ACCESS_KEY,
    });

    const store = readStore();
    expect(store.speakers.Alice.voiceprints).toHaveLength(1);
    const vp = store.speakers.Alice.voiceprints[0];
    expect(Array.from(decodeProfile(vp.profile))).toEqual([1, 2, 3, 4]);
    expect(vp.source).toBe("nota-test-audio.mp3");
  });

  it("appends to an existing profile", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({
      version: 3,
      speakers: {
        Alice: { voiceprints: [{ id: "old", profile: "AAA=", enrolledAt: "old", source: "o.m4a" }] },
      },
    });

    await enrollSpeaker(record.id, "Speaker 1", "Alice", {
      storePath,
      historyDir,
      accessKey: ACCESS_KEY,
    });

    expect(readStore().speakers.Alice.voiceprints).toHaveLength(2);
  });
});

describe("enrollSpeaker – error exit codes", () => {
  it("exit 4 when no AccessKey is available", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({ version: 3, speakers: {} });
    delete process.env.PICOVOICE_ACCESS_KEY;

    await expect(
      enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir, accessKey: undefined }),
    ).rejects.toMatchObject({ exitCode: 4 });
  });

  it("exit 2 when the history record does not exist", async () => {
    writeStore({ version: 3, speakers: {} });
    await expect(
      enrollSpeaker("nonexistent-id", "Speaker 1", "Alice", { storePath, historyDir, accessKey: ACCESS_KEY }),
    ).rejects.toMatchObject({ exitCode: 2 });
  });

  it("exit 3 when the speaker has no stored clip", async () => {
    const record = makeHistoryRecord({ speakerClips: {} });
    writeHistory(record);
    writeStore({ version: 3, speakers: {} });
    await expect(
      enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir, accessKey: ACCESS_KEY }),
    ).rejects.toMatchObject({ exitCode: 3 });
  });

  it("exit 3 when the clip pointer exists but the file is missing", async () => {
    const record = makeHistoryRecord();
    writeHistory(record); // note: no writeClip — file absent
    writeStore({ version: 3, speakers: {} });
    await expect(
      enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir, accessKey: ACCESS_KEY }),
    ).rejects.toMatchObject({ exitCode: 3 });
  });

  it("exit 5 when there is insufficient speech to enroll", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({ version: 3, speakers: {} });
    mockEnrollProfile.mockRejectedValueOnce(new InsufficientSpeechError());

    await expect(
      enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir, accessKey: ACCESS_KEY }),
    ).rejects.toMatchObject({ exitCode: 5 });
  });

  it("exit 1 on any other Eagle failure", async () => {
    const record = makeHistoryRecord();
    writeHistory(record);
    writeClip(record, "Speaker 1");
    writeStore({ version: 3, speakers: {} });
    mockEnrollProfile.mockRejectedValueOnce(new Error("boom"));

    await expect(
      enrollSpeaker(record.id, "Speaker 1", "Alice", { storePath, historyDir, accessKey: ACCESS_KEY }),
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
