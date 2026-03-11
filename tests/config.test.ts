import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { loadConfig } from "../src/config.js";

describe("loadConfig", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it("throws if OPENAI_API_KEY is missing", () => {
    delete process.env.OPENAI_API_KEY;
    expect(() => loadConfig({})).toThrow("OPENAI_API_KEY");
  });

  it("returns config with defaults when key present", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig({});
    expect(config.openaiApiKey).toBe("sk-test");
    expect(config.summaryModel).toBe("gpt-4o");
  });

  it("respects model override", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig({ model: "gpt-4o-mini" });
    expect(config.summaryModel).toBe("gpt-4o-mini");
  });

  it("defaults diarize to true", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig({});
    expect(config.diarize).toBe(true);
  });

  it("respects diarize false override", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig({ diarize: false });
    expect(config.diarize).toBe(false);
  });
});
