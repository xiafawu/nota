import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
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
    process.env.ANTHROPIC_API_KEY = "sk-ant-test";
    expect(() => loadConfig({})).toThrow("OPENAI_API_KEY");
  });

  it("throws if ANTHROPIC_API_KEY is missing", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    delete process.env.ANTHROPIC_API_KEY;
    expect(() => loadConfig({})).toThrow("ANTHROPIC_API_KEY");
  });

  it("returns config with defaults when keys present", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ANTHROPIC_API_KEY = "sk-ant-test";
    const config = loadConfig({});
    expect(config.openaiApiKey).toBe("sk-test");
    expect(config.anthropicApiKey).toBe("sk-ant-test");
    expect(config.claudeModel).toBe("claude-sonnet-4-20250514");
  });

  it("respects model override", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ANTHROPIC_API_KEY = "sk-ant-test";
    const config = loadConfig({ model: "claude-opus-4-20250514" });
    expect(config.claudeModel).toBe("claude-opus-4-20250514");
  });
});
