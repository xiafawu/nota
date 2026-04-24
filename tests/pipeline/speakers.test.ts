import { describe, it, expect } from "vitest";
import {
  cosineSimilarity,
  matchSpeakers,
  applySpeakerNames,
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

  it("does not match speakers below threshold", () => {
    const embeddings = {
      "Speaker 1": [0.5, 0.5, 0.5], // not close to anyone
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
});
