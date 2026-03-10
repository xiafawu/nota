import { describe, it, expect } from "vitest";
import { buildSummaryPrompt } from "../../src/pipeline/summarize.js";

describe("buildSummaryPrompt", () => {
  it("includes the transcript in the prompt", () => {
    const prompt = buildSummaryPrompt("Hello, this is a test meeting.");
    expect(prompt).toContain("Hello, this is a test meeting.");
    expect(prompt).toContain("Key Topics");
    expect(prompt).toContain("Action Items");
    expect(prompt).toContain("Decisions Made");
  });
});
