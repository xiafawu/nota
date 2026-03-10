import { describe, it, expect } from "vitest";
import { runPipeline } from "../src/orchestrator.js";

describe("orchestrator", () => {
  it("exports runPipeline function", () => {
    expect(runPipeline).toBeDefined();
    expect(typeof runPipeline).toBe("function");
  });
});
