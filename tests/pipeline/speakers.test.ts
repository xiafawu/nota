import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  applySpeakerNames,
  loadProfiles,
  saveProfiles,
  encodeProfile,
  decodeProfile,
  rankMatches,
} from "../../src/pipeline/speakers.js";
import type { SpeakerStore } from "../../src/pipeline/speakers.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";

describe("profile codec", () => {
  it("round-trips bytes through base64", () => {
    const bytes = new Uint8Array([0, 1, 250, 255, 42]);
    expect(Array.from(decodeProfile(encodeProfile(bytes)))).toEqual([0, 1, 250, 255, 42]);
  });
});

describe("rankMatches", () => {
  // names[i] is the speaker that the i-th enrolled voiceprint belongs to.
  const names = ["Alice", "Bob"];

  it("assigns the confident best name per label", () => {
    const out = rankMatches({ "Speaker 1": [0.9, 0.1], "Speaker 2": [0.05, 0.8] }, names);
    expect(out["Speaker 1"]).toEqual({ name: "Alice", confidence: 0.9 });
    expect(out["Speaker 2"]).toEqual({ name: "Bob", confidence: 0.8 });
  });

  it("flags the tentative band [0.4, 0.6)", () => {
    const out = rankMatches({ "Speaker 1": [0.5, 0.0] }, names);
    expect(out["Speaker 1"]).toEqual({ name: "Alice", confidence: 0.5, tentative: true });
  });

  it("treats exactly 0.6 as confident (boundary)", () => {
    const out = rankMatches({ "Speaker 1": [0.6, 0.0] }, names);
    expect(out["Speaker 1"].tentative).toBeUndefined();
  });

  it("drops scores below the tentative floor 0.4", () => {
    const out = rankMatches({ "Speaker 1": [0.39, 0.1] }, names);
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

describe("speaker store v3", () => {
  let dir: string;
  let file: string;
  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "nota-spk-"));
    file = path.join(dir, "speakers.json");
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("round-trips a v3 profile blob", async () => {
    const bytes = new Uint8Array([1, 2, 3, 4]);
    const store: SpeakerStore = {
      version: 3,
      speakers: {
        Alice: {
          voiceprints: [
            { id: "t", profile: encodeProfile(bytes), enrolledAt: "t", source: "a.m4a" },
          ],
        },
      },
    };
    await saveProfiles(store, file);
    const loaded = await loadProfiles(file);
    expect(loaded.version).toBe(3);
    expect(Array.from(decodeProfile(loaded.speakers.Alice.voiceprints[0].profile))).toEqual([
      1, 2, 3, 4,
    ]);
  });

  it("drops legacy embedding records on load", async () => {
    await writeFile(
      file,
      JSON.stringify({
        version: 2,
        speakers: {
          Bob: {
            voiceprints: [{ id: "t", embedding: [0.1, 0.2], enrolledAt: "t", source: "b.m4a" }],
          },
        },
      }),
    );
    const loaded = await loadProfiles(file);
    expect(loaded.speakers.Bob).toBeUndefined();
    expect(loaded.version).toBe(3);
  });

  it("returns an empty v3 store when no file exists", async () => {
    const loaded = await loadProfiles(file);
    expect(loaded.version).toBe(3);
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
