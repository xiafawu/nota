import { describe, it, expect } from "vitest";
import { estimateTokens, shouldChunkTranscript } from "../../src/utils/tokens.js";

describe("estimateTokens", () => {
  it("estimates roughly 1 token per 4 characters", () => {
    const text = "a".repeat(400);
    const tokens = estimateTokens(text);
    expect(tokens).toBeGreaterThanOrEqual(90);
    expect(tokens).toBeLessThanOrEqual(110);
  });
});

describe("shouldChunkTranscript", () => {
  it("returns false for short text", () => {
    expect(shouldChunkTranscript("short text")).toBe(false);
  });

  it("returns true for very long text", () => {
    const longText = "word ".repeat(200000);
    expect(shouldChunkTranscript(longText)).toBe(true);
  });
});
