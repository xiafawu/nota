import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, beforeEach, describe, it, expect, vi } from "vitest";

const embedMocks = vi.hoisted(() => ({
  isIdentityAvailable: vi.fn(),
  computeEmbeddings: vi.fn(),
  computeEmbedding: vi.fn(),
}));
const pcmMocks = vi.hoisted(() => ({ decodePcm: vi.fn() }));
const speakerMocks = vi.hoisted(() => ({
  loadProfiles: vi.fn(),
  saveProfiles: vi.fn(),
  matchProfiles: vi.fn(),
  promptForSpeakerNames: vi.fn(),
  applySpeakerNames: vi.fn(),
}));

vi.mock("../src/pipeline/embed.js", async () => {
  const actual = await vi.importActual<typeof import("../src/pipeline/embed.js")>(
    "../src/pipeline/embed.js",
  );
  return { ...actual, ...embedMocks };
});

vi.mock("../src/utils/pcm.js", async () => {
  const actual = await vi.importActual<typeof import("../src/utils/pcm.js")>(
    "../src/utils/pcm.js",
  );
  return { ...actual, decodePcm: pcmMocks.decodePcm };
});

vi.mock("../src/pipeline/speakers.js", async () => {
  const actual = await vi.importActual<typeof import("../src/pipeline/speakers.js")>(
    "../src/pipeline/speakers.js",
  );
  return { ...actual, ...speakerMocks };
});

import {
  identifySpeakers,
  resolveIdentifyActive,
  runPipeline,
  selectClipRanges,
} from "../src/orchestrator.js";
import type { AppConfig } from "../src/config.js";
import type { TranscriptSegment } from "../src/pipeline/transcribe.js";

beforeEach(() => {
  pcmMocks.decodePcm.mockResolvedValue(new Int16Array(6 * 16_000));
  speakerMocks.loadProfiles.mockResolvedValue({ version: 4, speakers: {} });
  speakerMocks.matchProfiles.mockReturnValue({});
  speakerMocks.promptForSpeakerNames.mockResolvedValue({ names: {}, enroll: {} });
  speakerMocks.applySpeakerNames.mockImplementation((segments) => segments);
  speakerMocks.saveProfiles.mockResolvedValue(undefined);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.clearAllMocks();
});

const config = {
  identify: true,
} as AppConfig;

describe("orchestrator", () => {
  it("exports runPipeline function", () => {
    expect(runPipeline).toBeDefined();
    expect(typeof runPipeline).toBe("function");
  });
});

describe("identifySpeakers", () => {
  it("keeps generic labels and explains how to restore ONNX identity when unavailable", async () => {
    embedMocks.isIdentityAvailable.mockResolvedValue(false);
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const segments: TranscriptSegment[] = [
      { start: 0, end: 6, text: "hello", speaker: "Speaker 1" },
    ];

    await expect(
      identifySpeakers("audio.wav", segments, config, false),
    ).resolves.toEqual({ segments, clips: {}, suggestions: [] });
    expect(error).toHaveBeenCalledWith(
      expect.stringMatching(/ONNX.*model.*onnxruntime-node/i),
    );
  });

  it("treats an unexpected availability rejection as a graceful no-op", async () => {
    embedMocks.isIdentityAvailable.mockRejectedValue(new Error("native import exploded"));
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const segments: TranscriptSegment[] = [
      { start: 0, end: 6, text: "hello", speaker: "Speaker 1" },
    ];

    await expect(
      identifySpeakers("audio.wav", segments, config, false),
    ).resolves.toEqual({ segments, clips: {}, suggestions: [] });
    expect(error).toHaveBeenCalledWith(expect.stringMatching(/ONNX.*model/i));
  });

  it("continues with generic labels when embedding inference fails", async () => {
    embedMocks.isIdentityAvailable.mockResolvedValue(true);
    embedMocks.computeEmbeddings.mockRejectedValue(new Error("inference failed"));
    const error = vi.spyOn(console, "error").mockImplementation(() => {});
    const segments: TranscriptSegment[] = [
      { start: 0, end: 6, text: "hello", speaker: "Speaker 1" },
    ];

    await expect(
      identifySpeakers("audio.wav", segments, config, false),
    ).resolves.toEqual({ segments, clips: {}, suggestions: [] });
    expect(error).toHaveBeenCalledWith(expect.stringMatching(/onnxruntime-node/i));
  });

  it("reuses the run's label embedding when enrolling a fresh name", async () => {
    embedMocks.isIdentityAvailable.mockResolvedValue(true);
    embedMocks.computeEmbeddings.mockResolvedValue({
      "Speaker 1": [0.6, 0.8],
    });
    speakerMocks.promptForSpeakerNames.mockResolvedValue({
      names: { "Speaker 1": "Alice" },
      enroll: { "Speaker 1": "Alice" },
    });
    const ttyDescriptor = Object.getOwnPropertyDescriptor(process.stdin, "isTTY");
    Object.defineProperty(process.stdin, "isTTY", {
      configurable: true,
      value: true,
    });
    const segments: TranscriptSegment[] = [
      { start: 0, end: 6, text: "hello", speaker: "Speaker 1" },
    ];

    try {
      await identifySpeakers("audio.wav", segments, config, false);
    } finally {
      if (ttyDescriptor) {
        Object.defineProperty(process.stdin, "isTTY", ttyDescriptor);
      } else {
        delete (process.stdin as NodeJS.ReadStream & { isTTY?: boolean }).isTTY;
      }
    }

    expect(embedMocks.computeEmbeddings).toHaveBeenCalledOnce();
    expect(embedMocks.computeEmbedding).not.toHaveBeenCalled();
    expect(speakerMocks.saveProfiles).toHaveBeenCalledWith(
      expect.objectContaining({
        speakers: {
          Alice: {
            voiceprints: [
              expect.objectContaining({ embedding: [0.6, 0.8] }),
            ],
          },
        },
      }),
    );
  });
});

describe("resolveIdentifyActive", () => {
  let dir: string;
  let storeFile: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "nota-idactive-"));
    storeFile = path.join(dir, "speakers.json");
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("forces on with --identify even on an empty store", async () => {
    await expect(resolveIdentifyActive({ identify: true }, storeFile)).resolves.toBe(true);
  });

  it("forces off with --no-identify even when voiceprints exist", async () => {
    await writeFile(
      storeFile,
      JSON.stringify({
        version: 4,
        speakers: { Alice: { voiceprints: [{ id: "t", embedding: [1], enrolledAt: "t", source: "a" }] } },
      }),
    );
    await expect(resolveIdentifyActive({ identify: false }, storeFile)).resolves.toBe(false);
  });

  it("auto-runs when the store has at least one enrolled speaker", async () => {
    speakerMocks.loadProfiles.mockResolvedValue({
      version: 4,
      speakers: {
        Alice: {
          voiceprints: [{ id: "t", embedding: [1], enrolledAt: "t", source: "a" }],
        },
      },
    });
    await expect(resolveIdentifyActive({ identify: undefined }, storeFile)).resolves.toBe(true);
  });

  it("auto no-ops on an empty or missing store", async () => {
    await expect(resolveIdentifyActive({ identify: undefined }, storeFile)).resolves.toBe(false);
  });
});

describe("selectClipRanges", () => {
  const segs: TranscriptSegment[] = [
    { start: 0, end: 2, text: "", speaker: "Speaker 1" },
    { start: 5, end: 15, text: "", speaker: "Speaker 1" },
    { start: 20, end: 22, text: "", speaker: "Speaker 1" },
    { start: 22, end: 30, text: "", speaker: "Speaker 2" },
  ];

  it("picks the longest utterances first up to the target seconds", () => {
    // The 10s utterance (5–15) alone meets a 10s target → stop there.
    expect(selectClipRanges(segs, "Speaker 1", 10)).toEqual([{ start: 5, end: 15 }]);
  });

  it("accumulates multiple utterances when one is not enough", () => {
    // target 11s: 10s utterance, then the next-longest (2s) to cross 11.
    const ranges = selectClipRanges(segs, "Speaker 1", 11);
    expect(ranges[0]).toEqual({ start: 5, end: 15 });
    expect(ranges).toHaveLength(2);
  });

  it("only includes the requested speaker", () => {
    const ranges = selectClipRanges(segs, "Speaker 2", 100);
    expect(ranges).toEqual([{ start: 22, end: 30 }]);
  });

  it("returns empty for an unknown speaker", () => {
    expect(selectClipRanges(segs, "Speaker 9", 10)).toEqual([]);
  });
});
