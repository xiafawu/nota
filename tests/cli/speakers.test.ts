import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  averageEmbeddings,
  deleteSpeaker,
  listSpeakers,
  mergeSpeakers,
  renameSpeaker,
  showSpeaker,
} from "../../src/cli/speakers.js";
import { cosineSimilarity } from "../../src/pipeline/speakers.js";
import type { SpeakerStore } from "../../src/pipeline/speakers.js";

let tempDir: string;
let storePath: string;
let stdoutSpy: ReturnType<typeof vi.spyOn>;
let stderrSpy: ReturnType<typeof vi.spyOn>;
let stdoutChunks: string[];
let stderrChunks: string[];

function writeStore(store: SpeakerStore): void {
  writeFileSync(storePath, JSON.stringify(store), "utf-8");
}

function readStore(): SpeakerStore {
  return JSON.parse(readFileSync(storePath, "utf-8")) as SpeakerStore;
}

beforeEach(() => {
  tempDir = mkdtempSync(path.join(tmpdir(), "nota-speakers-cli-"));
  storePath = path.join(tempDir, "speakers.json");
  stdoutChunks = [];
  stderrChunks = [];
  stdoutSpy = vi
    .spyOn(process.stdout, "write")
    .mockImplementation((chunk: unknown) => {
      stdoutChunks.push(typeof chunk === "string" ? chunk : String(chunk));
      return true;
    });
  stderrSpy = vi
    .spyOn(process.stderr, "write")
    .mockImplementation((chunk: unknown) => {
      stderrChunks.push(typeof chunk === "string" ? chunk : String(chunk));
      return true;
    });
});

afterEach(() => {
  stdoutSpy.mockRestore();
  stderrSpy.mockRestore();
  rmSync(tempDir, { recursive: true, force: true });
});

describe("listSpeakers", () => {
  it("prints empty notice on stderr when no speakers are enrolled", async () => {
    await listSpeakers({ storePath });
    expect(stdoutChunks.join("")).toBe("");
    expect(stderrChunks.join("")).toContain("No speakers enrolled.");
  });

  it("prints one tab-separated row per speaker on stdout", async () => {
    writeStore({
      version: 1,
      speakers: {
        Alice: {
          embedding: [1, 0, 0, 0],
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "demo.mp3",
        },
      },
    });

    await listSpeakers({ storePath });
    const lines = stdoutChunks.join("").trim().split("\n");
    expect(lines).toHaveLength(1);
    const [name, enrolledAt, source, length] = lines[0].split("\t");
    expect(name).toBe("Alice");
    expect(enrolledAt).toBe("2026-01-01T00:00:00.000Z");
    expect(source).toBe("demo.mp3");
    expect(length).toBe("4");
  });
});

describe("renameSpeaker", () => {
  it("throws when the source profile does not exist", async () => {
    writeStore({ version: 1, speakers: {} });
    await expect(
      renameSpeaker("Ghost", "Bob", { storePath }),
    ).rejects.toThrow(/Ghost/);
  });

  it("renames an existing profile and persists the change", async () => {
    writeStore({
      version: 1,
      speakers: {
        Alice: {
          embedding: [1, 0],
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "demo.mp3",
        },
      },
    });

    await renameSpeaker("Alice", "Alicia", { storePath });
    const after = readStore();
    expect(after.speakers.Alice).toBeUndefined();
    expect(after.speakers.Alicia).toBeDefined();
    expect(after.speakers.Alicia.embedding).toEqual([1, 0]);
  });

  it("refuses to overwrite an existing destination", async () => {
    writeStore({
      version: 1,
      speakers: {
        Alice: {
          embedding: [1, 0],
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "a.mp3",
        },
        Bob: {
          embedding: [0, 1],
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "b.mp3",
        },
      },
    });

    await expect(
      renameSpeaker("Alice", "Bob", { storePath }),
    ).rejects.toThrow(/Bob/);
  });
});

describe("deleteSpeaker", () => {
  it("removes the named speaker from disk", async () => {
    writeStore({
      version: 1,
      speakers: {
        Alice: {
          embedding: [1, 0],
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "demo.mp3",
        },
        Bob: {
          embedding: [0, 1],
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "demo.mp3",
        },
      },
    });

    await deleteSpeaker("Alice", { storePath });
    const after = readStore();
    expect(after.speakers.Alice).toBeUndefined();
    expect(after.speakers.Bob).toBeDefined();
  });

  it("throws when the speaker is not enrolled", async () => {
    writeStore({ version: 1, speakers: {} });
    await expect(
      deleteSpeaker("Ghost", { storePath }),
    ).rejects.toThrow(/Ghost/);
  });
});

describe("mergeSpeakers", () => {
  it("averages embeddings, renormalizes, and drops the source profile", async () => {
    // Two distinct unit vectors at the same magnitude
    const aliceEmbedding = [1, 0, 0];
    const aliceTwinEmbedding = [Math.SQRT1_2, Math.SQRT1_2, 0];

    writeStore({
      version: 1,
      speakers: {
        Alice: {
          embedding: aliceEmbedding,
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "a.mp3",
        },
        AliceAlt: {
          embedding: aliceTwinEmbedding,
          enrolledAt: "2026-01-02T00:00:00.000Z",
          source: "b.mp3",
        },
      },
    });

    await mergeSpeakers("AliceAlt", "Alice", { storePath });
    const after = readStore();
    expect(after.speakers.AliceAlt).toBeUndefined();
    expect(after.speakers.Alice).toBeDefined();

    const merged = after.speakers.Alice.embedding;
    const norm = Math.sqrt(merged.reduce((acc, v) => acc + v * v, 0));
    expect(norm).toBeCloseTo(1, 6);

    expect(cosineSimilarity(merged, aliceEmbedding)).toBeCloseTo(
      cosineSimilarity(
        averageEmbeddings(aliceEmbedding, aliceTwinEmbedding),
        aliceEmbedding,
      ),
      6,
    );

    // averageEmbeddings is symmetric: cosine to either original is equal
    const sim1 = cosineSimilarity(merged, aliceEmbedding);
    const sim2 = cosineSimilarity(merged, aliceTwinEmbedding);
    expect(sim1).toBeCloseTo(sim2, 6);
  });

  it("preserves cosine similarity ~1 when both inputs are identical", async () => {
    const embedding = [Math.SQRT1_2, Math.SQRT1_2, 0];
    writeStore({
      version: 1,
      speakers: {
        Alice: {
          embedding,
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "a.mp3",
        },
        AliceCopy: {
          embedding: embedding.slice(),
          enrolledAt: "2026-01-02T00:00:00.000Z",
          source: "b.mp3",
        },
      },
    });

    await mergeSpeakers("AliceCopy", "Alice", { storePath });
    const after = readStore();
    const merged = after.speakers.Alice.embedding;
    const norm = Math.sqrt(merged.reduce((acc, v) => acc + v * v, 0));
    expect(norm).toBeCloseTo(1, 6);
    expect(cosineSimilarity(merged, embedding)).toBeCloseTo(1, 6);
  });

  it("throws when either profile is missing", async () => {
    writeStore({
      version: 1,
      speakers: {
        Alice: {
          embedding: [1, 0],
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "a.mp3",
        },
      },
    });
    await expect(
      mergeSpeakers("Alice", "Ghost", { storePath }),
    ).rejects.toThrow(/Ghost/);
    await expect(
      mergeSpeakers("Ghost", "Alice", { storePath }),
    ).rejects.toThrow(/Ghost/);
  });
});

describe("showSpeaker", () => {
  it("prints a JSON view truncating embeddings to first 8 dims", async () => {
    const long = Array.from({ length: 20 }, (_, i) => i / 20);
    writeStore({
      version: 1,
      speakers: {
        Alice: {
          embedding: long,
          enrolledAt: "2026-01-01T00:00:00.000Z",
          source: "demo.mp3",
        },
      },
    });

    await showSpeaker("Alice", { storePath });
    const printed = stdoutChunks.join("");
    const parsed = JSON.parse(printed);
    expect(parsed.name).toBe("Alice");
    expect(parsed.embeddingLength).toBe(20);
    expect(parsed.embeddingPreview).toHaveLength(8);
    expect(parsed.embeddingPreview[0]).toBeCloseTo(0);
  });

  it("throws when the speaker is missing", async () => {
    writeStore({ version: 1, speakers: {} });
    await expect(
      showSpeaker("Ghost", { storePath }),
    ).rejects.toThrow(/Ghost/);
  });
});
