import { describe, expect, it, vi } from "vitest";
import {
  buildSpeakerRecommendationPrompt,
  createPromptSpeakerRecommendationProvider,
  getContextualSpeakerRecommendations,
  parseSpeakerRecommendations,
  type SpeakerRecommendationInput,
} from "../../src/pipeline/contextual-speakers.js";
import {
  promptForSpeakerResolutions,
  rankProfileCandidates,
} from "../../src/pipeline/speakers.js";
import type { SpeakerStore } from "../../src/pipeline/speakers.js";

const input: SpeakerRecommendationInput = {
  transcript: [
    { start: 0, end: 2, speaker: "Speaker 1", text: "I'm Alice, joining from product." },
    { start: 2, end: 4, speaker: "Speaker 2", text: "I can take the action item." },
  ],
  labels: [
    {
      label: "Speaker 1",
      category: "ambiguous-existing",
      acousticCandidates: [{ name: "Alice", confidence: 0.55 }],
    },
    {
      label: "Speaker 2",
      category: "new-unrecognized",
      acousticCandidates: [],
    },
  ],
  profiles: [
    { name: "Alice", description: { text: "Product lead", updatedAt: "t", sourceHistoryIds: [] } },
    { name: "Bob" },
  ],
};

describe("contextual speaker recommendations", () => {
  it("grounds candidates in enrolled profiles and gates new names on self-introduction", () => {
    const result = parseSpeakerRecommendations(
      JSON.stringify({
        resolutions: [
          {
            label: "Speaker 1",
            category: "ambiguous-existing",
            candidates: [
              { name: "Bob", confidence: 0.4, evidence: "role context" },
              { name: "Invented", confidence: 0.99, evidence: "hallucinated" },
            ],
          },
          {
            label: "Speaker 2",
            category: "new-unrecognized",
            proposedName: "Alice",
            confidence: 0.8,
            evidence: "explicit introduction",
          },
        ],
      }),
      input,
    );

    expect(result[0].candidates).toEqual([
      { name: "Bob", confidence: 0.4, evidence: "role context" },
    ]);
    expect(result[1].proposedName).toBeUndefined();
  });

  it("accepts a proposed new name only when the transcript says it", () => {
    const result = parseSpeakerRecommendations(
      JSON.stringify({
        resolutions: [
          {
            label: "Speaker 1",
            category: "new-unrecognized",
            proposedName: "Alice",
            confidence: 0.7,
          },
        ],
      }),
      input,
    );
    expect(result[0].proposedName).toBe("Alice");
  });

  it("returns no recommendations when a provider fails", async () => {
    const provider = createPromptSpeakerRecommendationProvider(async () => {
      throw new Error("offline");
    });
    await expect(getContextualSpeakerRecommendations(input, provider)).resolves.toEqual([]);
  });

  it("keeps the provider seam testable without constructing an API client", async () => {
    const complete = vi.fn().mockResolvedValue(
      '{"resolutions":[{"label":"Speaker 1","category":"ambiguous-existing","candidates":[{"name":"Alice","confidence":0.8,"evidence":"context"}]}]}',
    );
    const provider = createPromptSpeakerRecommendationProvider(complete);
    const result = await provider.recommend(input);
    expect(result[0].candidates[0].name).toBe("Alice");
    expect(complete).toHaveBeenCalledWith(expect.stringContaining("Enrolled profiles:"));
  });

  it("includes meeting context and the explicit category in the prompt", () => {
    const prompt = buildSpeakerRecommendationPrompt(input);
    expect(prompt).toContain("Speaker 1 [ambiguous-existing]");
    expect(prompt).toContain("I'm Alice");
    expect(prompt).toContain("Recommendations are advisory");
  });
});
describe("speaker resolution choices", () => {
  it("learns an explicitly selected existing candidate, but enrolls a confirmed new name", async () => {
    const answers = ["1", "y"];
    const result = await promptForSpeakerResolutions(
      input.transcript,
      [
        {
          label: "Speaker 1",
          category: "ambiguous-existing",
          candidates: [{ name: "Alice", confidence: 0.55, evidence: "acoustic" }],
        },
        {
          label: "Speaker 2",
          category: "new-unrecognized",
          proposedName: "Jordan",
          confidence: 0.6,
          evidence: "self-introduction",
        },
      ],
      {
        ask: async () => answers.shift() ?? "r",
        write: () => {},
      },
    );
    expect(result.names).toEqual({ "Speaker 1": "Alice", "Speaker 2": "Jordan" });
    expect(result.learn).toEqual({ "Speaker 1": "Alice" });
    expect(result.enroll).toEqual({ "Speaker 2": "Jordan" });
  });

  it("rejects all candidates without creating a profile decision", async () => {
    const result = await promptForSpeakerResolutions(
      input.transcript,
      [{
        label: "Speaker 1",
        category: "ambiguous-existing",
        candidates: [{ name: "Alice", confidence: 0.55, evidence: "acoustic" }],
      }],
      { ask: async () => "r", write: () => {} },
    );
    expect(result).toEqual({ names: {}, enroll: {}, learn: {} });
  });
});

describe("rankProfileCandidates", () => {
  it("retains multiple ranked profiles for an uncertain label", () => {
    const store: SpeakerStore = {
      version: 4,
      speakers: {
        Alice: { voiceprints: [{ id: "a", embedding: [1, 0], enrolledAt: "t", source: "a" }] },
        Bob: { voiceprints: [{ id: "b", embedding: [0.8, 0.6], enrolledAt: "t", source: "b" }] },
      },
    };
    expect(rankProfileCandidates({ "Speaker 1": [1, 0] }, store)["Speaker 1"]).toEqual([
      { name: "Alice", confidence: 1 },
      { name: "Bob", confidence: 0.8 },
    ]);
  });
});
