import { describe, it, expect, vi } from "vitest";
import { formatTimestamp } from "../../src/pipeline/transcribe.js";

describe("formatTimestamp", () => {
  it("formats seconds to [MM:SS]", () => {
    expect(formatTimestamp(0)).toBe("[00:00]");
    expect(formatTimestamp(65)).toBe("[01:05]");
    expect(formatTimestamp(3661)).toBe("[61:01]");
  });
});
