import { describe, it, expect } from "vitest";
import {
  cosineSimilarity,
  matchSpeakers,
  applySpeakerNames,
  clusterLabels,
  MERGE_THRESHOLD,
} from "../../src/pipeline/speakers.js";
import type { SpeakerStore } from "../../src/pipeline/speakers.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";

describe("cosineSimilarity", () => {
  it("returns 1 for identical vectors", () => {
    const v = [1, 0, 0, 0];
    expect(cosineSimilarity(v, v)).toBeCloseTo(1);
  });

  it("returns 0 for orthogonal vectors", () => {
    expect(cosineSimilarity([1, 0], [0, 1])).toBeCloseTo(0);
  });

  it("returns -1 for opposite vectors", () => {
    expect(cosineSimilarity([1, 0], [-1, 0])).toBeCloseTo(-1);
  });

  it("handles normalized vectors correctly", () => {
    const a = [0.6, 0.8];
    const b = [0.8, 0.6];
    // dot = 0.48 + 0.48 = 0.96, both are unit vectors
    expect(cosineSimilarity(a, b)).toBeCloseTo(0.96);
  });

  it("returns 0 for zero vectors", () => {
    expect(cosineSimilarity([0, 0], [1, 0])).toBe(0);
  });
});

describe("matchSpeakers", () => {
  const profiles: SpeakerStore = {
    version: 1,
    speakers: {
      Alice: {
        embedding: [1, 0, 0],
        enrolledAt: "2026-01-01",
        source: "test.mp3",
      },
      Bob: {
        embedding: [0, 1, 0],
        enrolledAt: "2026-01-01",
        source: "test.mp3",
      },
    },
  };

  it("matches speakers above threshold", () => {
    const embeddings = {
      "Speaker 1": [0.98, 0.05, 0.01], // close to Alice
      "Speaker 2": [0.02, 0.97, 0.03], // close to Bob
    };

    const matches = matchSpeakers(embeddings, profiles);
    expect(matches["Speaker 1"]?.name).toBe("Alice");
    expect(matches["Speaker 2"]?.name).toBe("Bob");
    expect(matches["Speaker 1"]?.confidence).toBeGreaterThan(0.7);
  });

  it("does not match speakers below LOW_CONFIDENCE", () => {
    // Cosine ~0.40 against Alice [1,0,0] and ~0.40 against Bob [0,1,0],
    // both below the 0.55 LOW_CONFIDENCE floor.
    const embeddings = {
      "Speaker 1": [0.4, 0.4, Math.sqrt(1 - 0.32)],
    };

    const matches = matchSpeakers(embeddings, profiles);
    expect(matches["Speaker 1"]).toBeUndefined();
  });

  it("returns empty for empty profiles", () => {
    const emptyStore: SpeakerStore = { version: 1, speakers: {} };
    const matches = matchSpeakers({ "Speaker 1": [1, 0, 0] }, emptyStore);
    expect(Object.keys(matches)).toHaveLength(0);
  });

  it("does not assign the same profile to two speakers", () => {
    const embeddings = {
      "Speaker 1": [0.99, 0.01, 0],  // very close to Alice
      "Speaker 2": [0.95, 0.05, 0],  // also close to Alice
    };

    const matches = matchSpeakers(embeddings, profiles);
    // Only the best match should claim Alice
    const names = Object.values(matches).map((m) => m.name);
    const aliceCount = names.filter((n) => n === "Alice").length;
    expect(aliceCount).toBeLessThanOrEqual(1);
  });
});

describe("applySpeakerNames", () => {
  it("replaces generic labels with real names", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello", speaker: "Speaker 1" },
      { start: 5, end: 10, text: "Hi", speaker: "Speaker 2" },
      { start: 10, end: 15, text: "Bye" },
    ];

    const result = applySpeakerNames(segments, {
      "Speaker 1": "Alice",
      "Speaker 2": "Bob",
    });

    expect(result[0].speaker).toBe("Alice");
    expect(result[1].speaker).toBe("Bob");
    expect(result[2].speaker).toBeUndefined();
  });

  it("keeps original label when no mapping exists", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello", speaker: "Speaker 3" },
    ];

    const result = applySpeakerNames(segments, {
      "Speaker 1": "Alice",
    });

    expect(result[0].speaker).toBe("Speaker 3");
  });

  it("rewrites sibling labels to canonical via labelMap", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "A", speaker: "Speaker 1" },
      { start: 5, end: 10, text: "B", speaker: "Speaker 2" },
      { start: 10, end: 15, text: "C", speaker: "Speaker 3" },
    ];

    // Speaker 2 is a sibling of Speaker 1; no name resolved yet.
    const labelMap = { "Speaker 1": "Speaker 1", "Speaker 2": "Speaker 1" };
    const result = applySpeakerNames(segments, {}, labelMap);

    expect(result[0].speaker).toBe("Speaker 1");
    expect(result[1].speaker).toBe("Speaker 1");
    expect(result[2].speaker).toBe("Speaker 3");
  });

  it("applies name resolution after canonical rewrite", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "A", speaker: "Speaker 1" },
      { start: 5, end: 10, text: "B", speaker: "Speaker 2" },
    ];

    const labelMap = { "Speaker 1": "Speaker 1", "Speaker 2": "Speaker 1" };
    const nameMap = { "Speaker 1": "Alice" };
    const result = applySpeakerNames(segments, nameMap, labelMap);

    expect(result[0].speaker).toBe("Alice");
    expect(result[1].speaker).toBe("Alice");
  });
});

describe("clusterLabels", () => {
  it("collapses two near-identical embeddings into one canonical", () => {
    const embeddings = {
      "Speaker 1": [1, 0, 0],
      "Speaker 2": [0.99, 0.01, 0],
    };

    const { canonicalOf, merged } = clusterLabels(embeddings);

    expect(canonicalOf["Speaker 1"]).toBe("Speaker 1");
    expect(canonicalOf["Speaker 2"]).toBe("Speaker 1");
    expect(Object.keys(merged)).toHaveLength(1);
    expect(merged["Speaker 1"]).toBeDefined();
  });

  it("keeps clearly different embeddings as separate clusters", () => {
    const embeddings = {
      "Speaker 1": [1, 0, 0],
      "Speaker 2": [0, 1, 0],
    };

    const { canonicalOf, merged } = clusterLabels(embeddings);

    expect(canonicalOf["Speaker 1"]).toBe("Speaker 1");
    expect(canonicalOf["Speaker 2"]).toBe("Speaker 2");
    expect(Object.keys(merged)).toHaveLength(2);
  });

  it("collapses a three-way cluster (A~B~C) into one canonical", () => {
    const embeddings = {
      A: [1, 0, 0],
      B: [0.97, 0.03, 0],
      C: [0.96, 0, 0.04],
    };

    const { canonicalOf, merged } = clusterLabels(embeddings);

    expect(canonicalOf.A).toBe("A");
    expect(canonicalOf.B).toBe("A");
    expect(canonicalOf.C).toBe("A");
    expect(Object.keys(merged)).toEqual(["A"]);
  });

  it("clusters transitively under single-linkage (A~B, B~C, A!~C)", () => {
    // Build vectors so cos(A,B) and cos(B,C) >= 0.85 but cos(A,C) < 0.85.
    const A = [1, 0, 0];
    // B at ~32 deg from A and ~32 deg from C: cos ~= 0.848 ... too low.
    // Use ~30 deg arms instead so the bridge holds: cos(30 deg) = 0.866.
    const B = [Math.cos(Math.PI / 6), Math.sin(Math.PI / 6), 0];
    const C = [Math.cos(Math.PI / 3), Math.sin(Math.PI / 3), 0];

    // Sanity: confirm the asymmetry the test depends on.
    expect(cosineSimilarity(A, B)).toBeGreaterThanOrEqual(MERGE_THRESHOLD);
    expect(cosineSimilarity(B, C)).toBeGreaterThanOrEqual(MERGE_THRESHOLD);
    expect(cosineSimilarity(A, C)).toBeLessThan(MERGE_THRESHOLD);

    const { canonicalOf, merged } = clusterLabels({ A, B, C });

    expect(canonicalOf.A).toBe("A");
    expect(canonicalOf.B).toBe("A");
    expect(canonicalOf.C).toBe("A");
    expect(Object.keys(merged)).toEqual(["A"]);
  });

  it("returns L2-normalized canonical embeddings", () => {
    const embeddings = {
      A: [2, 0, 0],
      B: [1.98, 0.02, 0],
    };

    const { merged } = clusterLabels(embeddings);
    const vec = merged.A;
    const norm = Math.sqrt(vec.reduce((sum, v) => sum + v * v, 0));
    expect(norm).toBeCloseTo(1);
  });

  it("returns empty maps for empty input", () => {
    const { canonicalOf, merged } = clusterLabels({});
    expect(canonicalOf).toEqual({});
    expect(merged).toEqual({});
  });
});

describe("matchSpeakers with clustering", () => {
  const profiles: SpeakerStore = {
    version: 1,
    speakers: {
      Alice: {
        embedding: [1, 0, 0],
        enrolledAt: "2026-01-01",
        source: "test.mp3",
      },
    },
  };

  it("matches once when two sibling labels point to the same person", () => {
    const embeddings = {
      "Speaker 1": [0.99, 0.01, 0],
      "Speaker 2": [0.98, 0.02, 0],
    };

    const matches = matchSpeakers(embeddings, profiles);

    // Both siblings collapsed to canonical "Speaker 1"; Alice resolves once.
    expect(matches["Speaker 1"]?.name).toBe("Alice");
    expect(matches["Speaker 2"]).toBeUndefined();
  });
});

describe("matchSpeakers confidence band", () => {
  const profiles: SpeakerStore = {
    version: 1,
    speakers: {
      Alice: {
        embedding: [1, 0, 0],
        enrolledAt: "2026-01-01",
        source: "test.mp3",
      },
    },
  };

  // For a unit reference vector [1,0,0], cosine of [a, sqrt(1-a^2), 0] is a.
  const vecForScore = (s: number): number[] => [s, Math.sqrt(1 - s * s), 0];

  it("auto-matches at 0.80 (no tentative flag)", () => {
    const embeddings = { "Speaker 1": vecForScore(0.8) };
    const matches = matchSpeakers(embeddings, profiles);

    expect(matches["Speaker 1"]?.name).toBe("Alice");
    expect(matches["Speaker 1"]?.confidence).toBeCloseTo(0.8, 5);
    expect(matches["Speaker 1"]?.tentative).toBeUndefined();
  });

  it("flags tentative at 0.65 (in 0.55-0.70 band)", () => {
    const embeddings = { "Speaker 1": vecForScore(0.65) };
    const matches = matchSpeakers(embeddings, profiles);

    expect(matches["Speaker 1"]?.name).toBe("Alice");
    expect(matches["Speaker 1"]?.confidence).toBeCloseTo(0.65, 5);
    expect(matches["Speaker 1"]?.tentative).toBe(true);
  });

  it("returns no match at 0.45 (below LOW_CONFIDENCE)", () => {
    const embeddings = { "Speaker 1": vecForScore(0.45) };
    const matches = matchSpeakers(embeddings, profiles);

    expect(matches["Speaker 1"]).toBeUndefined();
  });

  it("treats exactly 0.70 as confident (boundary)", () => {
    const embeddings = { "Speaker 1": vecForScore(0.70) };
    const matches = matchSpeakers(embeddings, profiles);

    expect(matches["Speaker 1"]?.tentative).toBeUndefined();
  });

  it("treats exactly 0.55 as tentative (boundary)", () => {
    const embeddings = { "Speaker 1": vecForScore(0.55) };
    const matches = matchSpeakers(embeddings, profiles);

    expect(matches["Speaker 1"]?.tentative).toBe(true);
  });
});
