import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { tmpdir } from "node:os";
import path from "node:path";
import { loadConfig } from "../src/config.js";
import type { NotaSettings } from "../src/utils/settings.js";

const NO_SETTINGS: NotaSettings = {};

describe("loadConfig", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
    // Point env-file and settings loaders at guaranteed-absent paths so these
    // tests stay hermetic on any machine.
    process.env.NOTA_ENV_FILE = path.join(
      tmpdir(),
      "nota-config-absent-for-tests",
    );
    process.env.NOTA_SETTINGS_FILE = path.join(
      tmpdir(),
      "nota-settings-absent-for-tests",
    );
    delete process.env.OPENAI_API_KEY;
    delete process.env.ASSEMBLYAI_API_KEY;
    delete process.env.GEMINI_API_KEY;
    delete process.env.PICOVOICE_ACCESS_KEY;
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it("defaults to universal transcription + gpt-5-mini summary", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig({}, NO_SETTINGS);
    expect(config.provider).toBe("assemblyai");
    expect(config.transcriptionModel).toBe("universal");
    expect(config.summaryModel).toBe("gpt-5-mini");
  });

  it("requires ASSEMBLYAI_API_KEY for the default assemblyai transcription", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    expect(() => loadConfig({}, NO_SETTINGS)).toThrow("ASSEMBLYAI_API_KEY");
  });

  it("requires OPENAI_API_KEY for the default gpt-5-mini summary", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    expect(() => loadConfig({}, NO_SETTINGS)).toThrow("OPENAI_API_KEY");
  });

  it("does NOT require OPENAI_API_KEY for assemblyai + gemini summary", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.GEMINI_API_KEY = "gem-test";
    const config = loadConfig({ model: "gemini-2.5-flash" }, NO_SETTINGS);
    expect(config.summaryModel).toBe("gemini-2.5-flash");
    expect(config.summaryApiKey).toBe("gem-test");
    expect(config.summaryBaseURL).toContain("generativelanguage.googleapis.com");
    expect(config.transcriptionApiKey).toBe("aai-test");
  });

  it("requires OPENAI_API_KEY for whisper-1 transcription", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.GEMINI_API_KEY = "gem-test";
    expect(() =>
      loadConfig(
        { provider: "whisper", model: "gemini-2.5-flash" },
        NO_SETTINGS,
      ),
    ).toThrow("OPENAI_API_KEY");
  });

  it("maps --provider whisper to whisper-1 and the whisper pipeline", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig({ provider: "whisper" }, NO_SETTINGS);
    expect(config.provider).toBe("whisper");
    expect(config.transcriptionModel).toBe("whisper-1");
    expect(config.transcriptionApiKey).toBe("sk-test");
  });

  it("does not require ASSEMBLYAI_API_KEY for whisper provider", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig({ provider: "whisper" }, NO_SETTINGS);
    expect(config.provider).toBe("whisper");
  });

  it("--transcribe-model overrides the --provider alias", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    // provider=assemblyai (default) but explicit whisper-1 wins → whisper pipeline
    const config = loadConfig(
      { transcribeModel: "whisper-1" },
      NO_SETTINGS,
    );
    expect(config.transcriptionModel).toBe("whisper-1");
    expect(config.provider).toBe("whisper");
  });

  it("honors settings.json for both models (CLI absent)", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.GEMINI_API_KEY = "gem-test";
    const config = loadConfig(
      {},
      {
        transcription: { model: "whisper-1" },
        summary: { model: "gemini-2.5-pro" },
      },
    );
    expect(config.transcriptionModel).toBe("whisper-1");
    expect(config.summaryModel).toBe("gemini-2.5-pro");
  });

  it("CLI flags beat settings.json", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig(
      { transcribeModel: "universal", model: "gpt-4o" },
      {
        transcription: { model: "whisper-1" },
        summary: { model: "gemini-2.5-pro" },
      },
    );
    expect(config.transcriptionModel).toBe("universal");
    expect(config.summaryModel).toBe("gpt-4o");
  });

  it("explicit transcription setting overrides the whisper provider alias", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig(
      { provider: "whisper" },
      { transcription: { model: "universal" } },
    );
    expect(config.transcriptionModel).toBe("universal");
    expect(config.provider).toBe("assemblyai");
  });

  it("rejects an unknown summary model", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    expect(() => loadConfig({ model: "gpt-9000" }, NO_SETTINGS)).toThrow(
      /Unknown summary model/,
    );
  });

  it("rejects a transcription model used as a summary model", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    expect(() => loadConfig({ model: "universal" }, NO_SETTINGS)).toThrow(
      /not a summary model/,
    );
  });

  it("defaults diarize to true for assemblyai", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    expect(loadConfig({}, NO_SETTINGS).diarize).toBe(true);
  });

  it("forces diarize true for assemblyai even with diarize:false", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    expect(loadConfig({ diarize: false }, NO_SETTINGS).diarize).toBe(true);
  });

  it("respects diarize false for whisper provider", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig(
      { diarize: false, provider: "whisper" },
      NO_SETTINGS,
    );
    expect(config.diarize).toBe(false);
  });

  it("passes numSpeakers through", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    expect(loadConfig({ numSpeakers: 4 }, NO_SETTINGS).numSpeakers).toBe(4);
  });

  it("throws for unsupported provider", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    expect(() => loadConfig({ provider: "local" }, NO_SETTINGS)).toThrow(
      "Unsupported provider",
    );
  });

  it("throws for invalid numSpeakers", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    expect(() => loadConfig({ numSpeakers: 0 }, NO_SETTINGS)).toThrow(
      "--num-speakers must be a positive integer",
    );
  });

  it("saves history by default and respects the override", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    expect(loadConfig({}, NO_SETTINGS).history).toBe(true);
    expect(loadConfig({ history: false }, NO_SETTINGS).history).toBe(false);
  });

  it("generates summary by default and respects --no-summary", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    expect(loadConfig({}, NO_SETTINGS).summary).toBe(true);
    expect(loadConfig({ summary: false }, NO_SETTINGS).summary).toBe(false);
  });

  it("does not expose the legacy Picovoice key in config", () => {
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.PICOVOICE_ACCESS_KEY = "pv-test";
    expect(loadConfig({}, NO_SETTINGS)).not.toHaveProperty("picovoiceAccessKey");
  });
});
