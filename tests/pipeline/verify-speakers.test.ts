import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  buildVerifyPrompt,
  parseVerdicts,
  applyVerdicts,
  verifySpeakers,
} from "../../src/pipeline/verify-speakers.js";
import type { MatchResult } from "../../src/pipeline/speakers.js";

const mockSegments = [
  { start: 0, end: 5, text: "Hello, I'm Alice", speaker: "Speaker 1" },
  { start: 5, end: 10, text: "Let me explain the project", speaker: "Speaker 1" },
  { start: 10, end: 15, text: "That sounds good", speaker: "Speaker 2" },
];

const mockMatches: Record<string, MatchResult> = {
  "Speaker 1": { name: "Alice", confidence: 0.85 },
  "Speaker 2": { name: "Bob", confidence: 0.72 },
};

describe("buildVerifyPrompt", () => {
  it("includes speaker profiles when available", () => {
    const prompt = buildVerifyPrompt(mockSegments, mockMatches, {
      "Speaker 1": {
        name: "Alice",
        description: {
          text: "Alice is a project manager who leads standups.",
          updatedAt: "2026-07-01T00:00:00.000Z",
          sourceHistoryIds: ["rec-1"],
        },
      },
    });
    expect(prompt).toContain("Alice");
    expect(prompt).toContain("Stored Speaker Profiles");
    expect(prompt).toContain("project manager");
  });

  it("works without any speaker descriptions", () => {
    const prompt = buildVerifyPrompt(mockSegments, mockMatches, {
      "Speaker 1": { name: "Alice" },
      "Speaker 2": { name: "Bob" },
    });
    expect(prompt).toContain("Alice");
    expect(prompt).not.toContain("Stored Speaker Profiles");
  });
});

describe("parseVerdicts", () => {
  it("parses valid JSON lines", () => {
    const input = `
{"label":"Speaker 1","verdict":"consistent","role":"presenter"}
{"label":"Speaker 2","verdict":"conflict","evidence":"I don't work here","role":"customer"}
`;
    const result = parseVerdicts(input);
    expect(result).toHaveLength(2);
    expect(result[0]).toEqual({
      label: "Speaker 1",
      verdict: "consistent",
      role: "presenter",
    });
    expect(result[1]).toEqual({
      label: "Speaker 2",
      verdict: "conflict",
      evidence: "I don't work here",
      role: "customer",
    });
  });

  it("skips non-JSON lines", () => {
      const input = 'some text\n{"label":"S1","verdict":"consistent"}\nmore noise';
    const result = parseVerdicts(input);
    expect(result).toHaveLength(1);
  });

  it("returns empty for empty input", () => {
    expect(parseVerdicts("")).toEqual([]);
  });
});

describe("applyVerdicts", () => {
  it("demotes a confident match to tentative on conflict", () => {
    const updated = applyVerdicts(mockMatches, [
      { label: "Speaker 1", verdict: "conflict", evidence: "Inconsistency" },
    ]);
    expect(updated["Speaker 1"].tentative).toBe(true);
    expect(updated["Speaker 1"].name).toBe("Alice");
  });

  it("leaves matches unchanged on consistent", () => {
    const updated = applyVerdicts(mockMatches, [
      { label: "Speaker 1", verdict: "consistent", role: "presenter" },
    ]);
    expect(updated["Speaker 1"].tentative).toBeUndefined();
  });

  it("leaves matches unchanged on insufficient-evidence", () => {
    const updated = applyVerdicts(mockMatches, [
      { label: "Speaker 1", verdict: "insufficient-evidence" },
    ]);
    expect(updated["Speaker 1"].tentative).toBeUndefined();
  });

  it("ignores verdicts for labels not in matches", () => {
    const updated = applyVerdicts(mockMatches, [
      { label: "Speaker 3", verdict: "conflict" },
    ]);
    expect(Object.keys(updated)).toEqual(["Speaker 1", "Speaker 2"]);
  });

  it("does not rename on conflict", () => {
    const updated = applyVerdicts(mockMatches, [
      { label: "Speaker 1", verdict: "conflict" },
    ]);
    expect(updated["Speaker 1"].name).toBe("Alice");
  });

  it("does not change the match object shape on consistent verdict", () => {
    const updated = applyVerdicts(mockMatches, [
      { label: "Speaker 1", verdict: "consistent" },
    ]);
    expect(updated["Speaker 1"]).toEqual(mockMatches["Speaker 1"]);
  });
});

describe("verifySpeakers mocked", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("returns empty for no confident matches", async () => {
    const allTentative: Record<string, MatchResult> = {
      "Speaker 1": { name: "Alice", confidence: 0.55, tentative: true },
    };
    const result = await verifySpeakers(
      { segments: mockSegments, matches: allTentative, speakerContexts: {} },
      "sk-test",
      "gpt-5-mini",
    );
    expect(result).toEqual([]);
  });
});
