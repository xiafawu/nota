import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  applySpeakerNames,
  computeSuggestions,
  enrollVoiceprintWithCheck,
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

  it("flags the tentative band [0.5, 0.65)", () => {
    const out = rankMatches({ "Speaker 1": [0.55, 0.0] }, names);
    expect(out["Speaker 1"]).toEqual({ name: "Alice", confidence: 0.55, tentative: true });
  });

  it("treats exactly 0.65 as confident (boundary)", () => {
    const out = rankMatches({ "Speaker 1": [0.65, 0.0] }, names);
    expect(out["Speaker 1"].tentative).toBeUndefined();
  });

  it("drops scores below the tentative floor 0.5", () => {
    const out = rankMatches({ "Speaker 1": [0.49, 0.1] }, names);
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
    // then falls back to its Bob candidate (0.65, confident).
    const out = rankMatches({ "Speaker 1": [0.8, 0.65], "Speaker 2": [0.95, 0.1] }, names);
    expect(out["Speaker 2"]).toEqual({ name: "Alice", confidence: 0.95 });
    expect(out["Speaker 1"]).toEqual({ name: "Bob", confidence: 0.65 });
  });

  it("returns empty for no candidates", () => {
    expect(rankMatches({}, names)).toEqual({});
  });

  // --- margin gate (open-set rejection) ---
  it("rejects a label when the margin to second-best is below threshold", () => {
    // top1=0.7 (Alice), top2=0.68 (Bob), margin=0.02 < 0.06 → no match
    const out = rankMatches({ "Speaker 1": [0.7, 0.68] }, names);
    expect(out["Speaker 1"]).toBeUndefined();
  });

  it("accepts a label with sufficient margin", () => {
    // top1=0.8 (Alice), top2=0.1 (Bob), margin=0.7 >= 0.06 → match
    const out = rankMatches({ "Speaker 1": [0.8, 0.1] }, names);
    expect(out["Speaker 1"]).toEqual({ name: "Alice", confidence: 0.8 });
  });

  it("drops an unenrolled speaker whose scores straddle the threshold with low margin", () => {
    // top1=0.66 (Alice), top2=0.64 (Bob), margin=0.02 < 0.06 → no match
    const out = rankMatches({ "Speaker 1": [0.66, 0.64] }, names);
    expect(out["Speaker 1"]).toBeUndefined();
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

  it("preserves stored descriptions for contextual recommendations", async () => {
    await writeFile(
      file,
      JSON.stringify({
        version: 4,
        speakers: {
          Alice: {
            voiceprints: [{ id: "t", embedding: [1, 0], enrolledAt: "t", source: "a" }],
            description: {
              text: "Product lead",
              updatedAt: "2026-07-01T00:00:00.000Z",
              sourceHistoryIds: ["history-1"],
            },
          },
        },
      }),
    );
    const loaded = await loadProfiles(file);
    expect(loaded.speakers.Alice.description).toEqual({
      text: "Product lead",
      updatedAt: "2026-07-01T00:00:00.000Z",
      sourceHistoryIds: ["history-1"],
    });
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

describe("computeSuggestions", () => {
  const store: SpeakerStore = {
    version: 4,
    speakers: {
      Alice: {
        voiceprints: [{ id: "alice-1", embedding: [1, 0], enrolledAt: "t1", source: "a.m4a" }],
      },
      Bob: {
        voiceprints: [{ id: "bob-1", embedding: [0, 1], enrolledAt: "t2", source: "b.m4a" }],
      },
    },
  };
  // Single-speaker store for the band boundaries: any [x, y] unit vector
  // scores x against Alice and y against Bob, so a second enrolled name would
  // otherwise capture the y component and change the best candidate.
  const aliceOnly: SpeakerStore = {
    version: 4,
    speakers: {
      Alice: {
        voiceprints: [{ id: "alice-1", embedding: [1, 0], enrolledAt: "t1", source: "a.m4a" }],
      },
    },
  };

  it("suggests at the tentative floor 0.50 (inclusive)", () => {
    // (cos 60°) = [0.5, 0.866] → dot with Alice's [1, 0] is exactly 0.50
    // (within float epsilon of the norm-scaled dot product).
    const out = computeSuggestions({ "Speaker 1": [0.5, Math.sqrt(3) / 2] }, aliceOnly);
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({
      label: "Speaker 1",
      suggestedName: "Alice",
      voiceprintId: "alice-1",
      state: "pending",
    });
    expect(out[0].score).toBeCloseTo(0.5, 12);
  });

  it("suggests just below the match threshold 0.649", () => {
    // [0.649, sqrt(1 − 0.649²)] is unit length; dot with [1, 0] = 0.649.
    const out = computeSuggestions(
      { "Speaker 1": [0.649, Math.sqrt(1 - 0.649 * 0.649)] },
      aliceOnly,
    );
    expect(out[0]).toMatchObject({
      suggestedName: "Alice",
      score: 0.649,
      state: "pending",
    });
  });

  it("treats exactly 0.65 as confident — no suggestion (auto-labeled instead)", () => {
    const out = computeSuggestions({ "Speaker 1": [0.65, Math.sqrt(1 - 0.65 * 0.65)] }, aliceOnly);
    expect(out).toEqual([]);
  });

  it("drops scores below the tentative floor (0.49)", () => {
    const out = computeSuggestions({ "Speaker 1": [0.49, Math.sqrt(1 - 0.49 * 0.49)] }, aliceOnly);
    expect(out).toEqual([]);
  });

  it("uses the best voiceprint and reports its id", () => {
    const multi: SpeakerStore = {
      version: 4,
      speakers: {
        Alice: {
          voiceprints: [
            { id: "alice-old", embedding: [0.2, Math.sqrt(1 - 0.2 * 0.2)], enrolledAt: "t1", source: "a.m4a" },
            { id: "alice-new", embedding: [0.6, Math.sqrt(1 - 0.6 * 0.6)], enrolledAt: "t2", source: "a.m4a" },
          ],
        },
      },
    };
    const out = computeSuggestions({ "Speaker 1": [1, 0] }, multi);
    expect(out[0]).toMatchObject({ suggestedName: "Alice", score: 0.6, voiceprintId: "alice-new" });
  });

  it("suggests the same name for two labels independently (no global claiming)", () => {
    const out = computeSuggestions(
      {
        "Speaker 1": [0.55, Math.sqrt(1 - 0.55 * 0.55)],
        "Speaker 2": [0.52, Math.sqrt(1 - 0.52 * 0.52)],
      },
      aliceOnly,
    );
    expect(out.map((s) => s.label)).toEqual(["Speaker 1", "Speaker 2"]);
    expect(out.every((s) => s.suggestedName === "Alice")).toBe(true);
  });

  it("returns an empty list for an empty store or no embeddings", () => {
    expect(computeSuggestions({ "Speaker 1": [0.55, 0.5] }, { version: 4, speakers: {} })).toEqual([]);
    expect(computeSuggestions({}, store)).toEqual([]);
  });
});

describe("enrollVoiceprintWithCheck", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });
  const baseStore = (): SpeakerStore => ({
    version: 4,
    speakers: {
      Alice: {
        voiceprints: [{ id: "alice-1", embedding: [1, 0], enrolledAt: "t1", source: "a.m4a" }],
      },
    },
  });

  it("appends a first voiceprint without comparison or flag", () => {
    const store = { version: 4, speakers: {} } as SpeakerStore;
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    const out = enrollVoiceprintWithCheck(store, "New", [1, 0], "x.m4a");
    expect(out.agreement).toBeNull();
    expect(out.lowAgreement).toBe(false);
    expect(store.speakers.New.voiceprints).toHaveLength(1);
    expect(stderr).not.toHaveBeenCalled();
  });

  it("flags and warns when the new print strongly disagrees (0.025)", () => {
    const store = baseStore();
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    const out = enrollVoiceprintWithCheck(store, "Alice", [0.025, Math.sqrt(1 - 0.025 * 0.025)], "b.m4a");
    expect(out.agreement).toBeCloseTo(0.025, 3);
    expect(out.lowAgreement).toBe(true);
    expect(out.voiceprint.lowAgreement).toBe(true);
    expect(stderr).toHaveBeenCalledWith(
      expect.stringContaining('scores 0.025 against the best existing voiceprint'),
    );
  });

  it("does not flag an agreeing print (0.8)", () => {
    const store = baseStore();
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    const out = enrollVoiceprintWithCheck(store, "Alice", [0.8, Math.sqrt(1 - 0.8 * 0.8)], "b.m4a");
    expect(out.lowAgreement).toBe(false);
    expect(out.voiceprint.lowAgreement).toBeUndefined();
    expect(stderr).not.toHaveBeenCalled();
  });

  it("keeps the lowAgreement flag through a store round-trip", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "nota-spk-agree-"));
    try {
      const store = baseStore();
      enrollVoiceprintWithCheck(store, "Alice", [0.1, Math.sqrt(1 - 0.1 * 0.1)], "b.m4a");
      const file = path.join(dir, "speakers.json");
      await saveProfiles(store, file);
      const loaded = await loadProfiles(file);
      expect(loaded.speakers.Alice.voiceprints.map((vp) => vp.lowAgreement)).toEqual([
        undefined,
        true,
      ]);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
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
