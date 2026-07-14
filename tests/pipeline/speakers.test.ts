import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  applySpeakerNames,
  loadProfiles,
  matchProfiles,
  saveProfiles,
  rankMatches,
} from "../../src/pipeline/speakers.js";
import type { SpeakerStore } from "../../src/pipeline/speakers.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";

describe("rankMatches", () => {
  // names[i] is the speaker that the i-th enrolled voiceprint belongs to.
  const names = ["Alice", "Bob"];

  it("assigns the confident best name per label", () => {
    const out = rankMatches({ "Speaker 1": [0.9, 0.1], "Speaker 2": [0.05, 0.8] }, names);
    expect(out["Speaker 1"]).toEqual({ name: "Alice", confidence: 0.9 });
    expect(out["Speaker 2"]).toEqual({ name: "Bob", confidence: 0.8 });
  });

  it("flags the tentative band [0.35, 0.5)", () => {
    const out = rankMatches({ "Speaker 1": [0.49, 0.0] }, names);
    expect(out["Speaker 1"]).toEqual({ name: "Alice", confidence: 0.49, tentative: true });
  });

  it("treats exactly 0.5 as confident (boundary)", () => {
    const out = rankMatches({ "Speaker 1": [0.5, 0.0] }, names);
    expect(out["Speaker 1"].tentative).toBeUndefined();
  });

  it("drops scores below the tentative floor 0.35", () => {
    const out = rankMatches({ "Speaker 1": [0.34, 0.1] }, names);
    expect(out["Speaker 1"]).toBeUndefined();
  });

  it("claims each name at most once; lower-scoring label loses", () => {
    // Both labels best-match Alice; only the higher one (Speaker 1) wins her.
    const out = rankMatches({ "Speaker 1": [0.9, 0.2], "Speaker 2": [0.7, 0.1] }, names);
    expect(out["Speaker 1"]).toEqual({ name: "Alice", confidence: 0.9 });
    // Speaker 2's only remaining candidate (Bob 0.1) is below floor → unmatched.
    expect(out["Speaker 2"]).toBeUndefined();
  });

  it("resolves a conflict globally by score, not iteration order", () => {
    // Speaker 2 prefers Alice (0.95) over Speaker 1 (Alice 0.8); Speaker 1
    // then falls back to its Bob candidate (0.65, tentative).
    const out = rankMatches({ "Speaker 1": [0.8, 0.65], "Speaker 2": [0.95, 0.1] }, names);
    expect(out["Speaker 2"]).toEqual({ name: "Alice", confidence: 0.95 });
    expect(out["Speaker 1"]).toEqual({ name: "Bob", confidence: 0.65 });
  });

  it("returns empty for no candidates", () => {
    expect(rankMatches({}, names)).toEqual({});
  });
});

describe("matchProfiles", () => {
  it("matches label embeddings to stored voiceprints by cosine", () => {
    const store: SpeakerStore = {
      version: 4,
      speakers: {
        Alice: {
          voiceprints: [{ id: "a", embedding: [1, 0], enrolledAt: "t", source: "a.m4a" }],
        },
        Bob: {
          voiceprints: [{ id: "b", embedding: [0, 1], enrolledAt: "t", source: "b.m4a" }],
        },
      },
    };

    expect(matchProfiles({ "Speaker 1": [1, 0], "Speaker 2": [0, 1] }, store)).toEqual({
      "Speaker 1": { name: "Alice", confidence: 1 },
      "Speaker 2": { name: "Bob", confidence: 1 },
    });
  });

  it("uses the best cosine across multiple voiceprints for one name", () => {
    const store: SpeakerStore = {
      version: 4,
      speakers: {
        Alice: {
          voiceprints: [
            { id: "old", embedding: [-1, 0], enrolledAt: "t1", source: "old.m4a" },
            { id: "new", embedding: [0.8, 0.6], enrolledAt: "t2", source: "new.m4a" },
          ],
        },
        Bob: {
          voiceprints: [{ id: "b", embedding: [0, 1], enrolledAt: "t", source: "b.m4a" }],
        },
      },
    };

    expect(matchProfiles({ "Speaker 1": [0.8, 0.6] }, store)["Speaker 1"]).toEqual({
      name: "Alice",
      confidence: 1,
    });
  });
});

describe("speaker store v4", () => {
  let dir: string;
  let file: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "nota-spk-"));
    file = path.join(dir, "speakers.json");
  });
  afterEach(async () => {
    vi.restoreAllMocks();
    await rm(dir, { recursive: true, force: true });
  });

  it("round-trips a v4 embedding", async () => {
    const store: SpeakerStore = {
      version: 4,
      speakers: {
        Alice: {
          voiceprints: [
            { id: "t", embedding: [0.25, -0.5, 0.75], enrolledAt: "t", source: "a.m4a" },
          ],
        },
      },
    };
    await saveProfiles(store, file);
    const loaded = await loadProfiles(file);
    expect(loaded.version).toBe(4);
    expect(loaded.speakers.Alice.voiceprints[0].embedding).toEqual([0.25, -0.5, 0.75]);
  });

  it("drops v3 Eagle profiles and warns that re-enrollment is required", async () => {
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    await writeFile(
      file,
      JSON.stringify({
        version: 3,
        speakers: {
          Bob: {
            voiceprints: [{ id: "t", profile: "AQID", enrolledAt: "t", source: "b.m4a" }],
          },
        },
      }),
    );
    const loaded = await loadProfiles(file);
    expect(loaded.speakers.Bob).toBeUndefined();
    expect(loaded.version).toBe(4);
    expect(stderr).toHaveBeenCalledWith(
      "dropped 1 Eagle speaker profile(s) incompatible with the ONNX backend; re-enroll to restore.\n",
    );
  });

  it("keeps valid embeddings while dropping Eagle voiceprints from a mixed store", async () => {
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    await writeFile(
      file,
      JSON.stringify({
        version: 4,
        speakers: {
          Alice: {
            voiceprints: [
              { id: "onnx", embedding: [1, 0], enrolledAt: "t", source: "new.m4a" },
              { id: "eagle", profile: "AQID", enrolledAt: "t", source: "old.m4a" },
            ],
          },
        },
      }),
    );

    const loaded = await loadProfiles(file);

    expect(loaded.speakers.Alice.voiceprints).toEqual([
      { id: "onnx", embedding: [1, 0], enrolledAt: "t", source: "new.m4a" },
    ]);
    expect(stderr).toHaveBeenCalledWith(
      "dropped 1 Eagle speaker profile(s) incompatible with the ONNX backend; re-enroll to restore.\n",
    );
  });

  it("loads only non-empty numeric embedding arrays", async () => {
    await writeFile(
      file,
      JSON.stringify({
        version: 4,
        speakers: {
          Alice: {
            voiceprints: [
              { id: "valid", embedding: [1, 0], enrolledAt: "t", source: "a.m4a" },
              { id: "empty", embedding: [], enrolledAt: "t", source: "b.m4a" },
              { id: "string", embedding: [1, "0"], enrolledAt: "t", source: "c.m4a" },
            ],
          },
        },
      }),
    );

    const loaded = await loadProfiles(file);

    expect(loaded.speakers.Alice.voiceprints.map(({ id }) => id)).toEqual(["valid"]);
  });

  it("returns an empty v4 store when no file exists", async () => {
    const loaded = await loadProfiles(file);
    expect(loaded.version).toBe(4);
    expect(loaded.speakers).toEqual({});
  });
});

describe("applySpeakerNames", () => {
  it("replaces generic labels with real names", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello", speaker: "Speaker 1" },
      { start: 5, end: 10, text: "Hi", speaker: "Speaker 2" },
      { start: 10, end: 15, text: "Bye" },
    ];
    const result = applySpeakerNames(segments, { "Speaker 1": "Alice", "Speaker 2": "Bob" });
    expect(result[0].speaker).toBe("Alice");
    expect(result[1].speaker).toBe("Bob");
    expect(result[2].speaker).toBeUndefined();
  });

  it("keeps original label when no mapping exists", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello", speaker: "Speaker 3" },
    ];
    const result = applySpeakerNames(segments, { "Speaker 1": "Alice" });
    expect(result[0].speaker).toBe("Speaker 3");
  });

  it("rewrites sibling labels to canonical via labelMap then applies names", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "A", speaker: "Speaker 1" },
      { start: 5, end: 10, text: "B", speaker: "Speaker 2" },
    ];
    const labelMap = { "Speaker 1": "Speaker 1", "Speaker 2": "Speaker 1" };
    const result = applySpeakerNames(segments, { "Speaker 1": "Alice" }, labelMap);
    expect(result[0].speaker).toBe("Alice");
    expect(result[1].speaker).toBe("Alice");
  });
});
