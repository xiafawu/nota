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
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    const config = loadConfig({});
    expect(config.openaiApiKey).toBe("sk-test");
    expect(config.summaryModel).toBe("gpt-4o");
  });

  it("respects model override", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    const config = loadConfig({ model: "gpt-4o-mini" });
    expect(config.summaryModel).toBe("gpt-4o-mini");
  });

  it("defaults diarize to true", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    const config = loadConfig({});
    expect(config.diarize).toBe(true);
  });

  it("respects diarize false override for whisper provider", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig({ diarize: false, provider: "whisper" });
    expect(config.diarize).toBe(false);
  });

  it("defaults provider to assemblyai", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    const config = loadConfig({});
    expect(config.provider).toBe("assemblyai");
  });

  it("throws if ASSEMBLYAI_API_KEY is missing for assemblyai provider", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    delete process.env.ASSEMBLYAI_API_KEY;
    expect(() => loadConfig({})).toThrow("ASSEMBLYAI_API_KEY");
  });

  it("does not require ASSEMBLYAI_API_KEY for whisper provider", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    delete process.env.ASSEMBLYAI_API_KEY;
    const config = loadConfig({ provider: "whisper" });
    expect(config.provider).toBe("whisper");
  });

  it("forces diarize true for assemblyai provider", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    const config = loadConfig({ diarize: false });
    expect(config.diarize).toBe(true);
  });

  it("passes numSpeakers through", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    const config = loadConfig({ numSpeakers: 4 });
    expect(config.numSpeakers).toBe(4);
  });

  it("throws for unsupported provider", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    expect(() => loadConfig({ provider: "local" })).toThrow(
      "Unsupported provider",
    );
  });

  it("throws for invalid numSpeakers", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    expect(() => loadConfig({ numSpeakers: 0 })).toThrow(
      "--num-speakers must be a positive integer",
    );
  });

  it("saves history by default", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    const config = loadConfig({});
    expect(config.history).toBe(true);
  });

  it("respects history false override", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    const config = loadConfig({ history: false });
    expect(config.history).toBe(false);
  });
});
