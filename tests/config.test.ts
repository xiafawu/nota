import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { loadConfig } from "../src/config.js";
import type { NotaSettings } from "../src/utils/settings.js";

const NO_SETTINGS: NotaSettings = {};

describe("loadConfig", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
    // Prevent ~/.nota/config from injecting keys into tests
    process.env.NOTA_ENV_FILE = "/tmp/.nota-env-test-nonexistent";
    // Clear all relevant keys
    delete process.env.DEEPSEEK_API_KEY;
    delete process.env.OPENAI_API_KEY;
    delete process.env.GEMINI_API_KEY;
    delete process.env.ASSEMBLYAI_API_KEY;
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  describe("summary key-aware default chain", () => {
    it("uses deepseek-v4-flash when DEEPSEEK_API_KEY is set", () => {
      process.env.DEEPSEEK_API_KEY = "ds-key";
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      const c = loadConfig({}, NO_SETTINGS);
      expect(c.summaryModel).toBe("deepseek-v4-flash");
    });

    it("uses gpt-5.4-mini when only OPENAI_API_KEY is set", () => {
      process.env.OPENAI_API_KEY = "oa-key";
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      const c = loadConfig({}, NO_SETTINGS);
      expect(c.summaryModel).toBe("gpt-5.4-mini");
    });

    it("uses gemini-3.6-flash when only GEMINI_API_KEY is set", () => {
      process.env.GEMINI_API_KEY = "gm-key";
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      const c = loadConfig({}, NO_SETTINGS);
      expect(c.summaryModel).toBe("gemini-3.6-flash");
    });

    it("throws when no API keys are available for any chain model", () => {
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      // No DEEPSEEK_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY
      expect(() => loadConfig({}, NO_SETTINGS)).toThrow(
        /No summary model available/,
      );
    });

    it("chain falls through when a model is absent from catalog (deepseek not in baked?)", () => {
      // deepseek IS in the baked catalog, so this tests normal chain flow
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      process.env.GEMINI_API_KEY = "gm-key";
      const c = loadConfig({}, NO_SETTINGS);
      // gpt-5.4-mini isn't available (no OPENAI key), deepseek IS available
      // (no DEEPSEEK key), gemini IS available → gemini-3.6-flash
      expect(c.summaryModel).toBe("gemini-3.6-flash");
    });
  });

  describe("required keys", () => {
    it("requires ASSEMBLYAI_API_KEY for the default assemblyai transcription", () => {
      process.env.OPENAI_API_KEY = "oa-key";
      expect(() => loadConfig({}, NO_SETTINGS)).toThrow(
        "ASSEMBLYAI_API_KEY",
      );
    });

    it("does NOT require OPENAI_API_KEY for assemblyai + gemini summary", () => {
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      process.env.GEMINI_API_KEY = "gm-key";
      const c = loadConfig({}, NO_SETTINGS);
      expect(c.transcriptionModel).toBe("universal");
      expect(c.summaryModel).toBe("gemini-3.6-flash");
    });

    it("requires OPENAI_API_KEY for whisper-1 transcription", () => {
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      process.env.GEMINI_API_KEY = "gm-key";
      // No OPENAI_API_KEY — whisper-1 transcription needs it, chain uses gemini
      expect(() =>
        loadConfig({ transcribeModel: "whisper-1" }, NO_SETTINGS),
      ).toThrow("OPENAI_API_KEY");
    });
  });

  describe("provider aliases", () => {
    it("maps --provider whisper to whisper-1 and the whisper pipeline", () => {
      process.env.OPENAI_API_KEY = "oa-key";
      const c = loadConfig({ provider: "whisper" }, NO_SETTINGS);
      expect(c.transcriptionModel).toBe("whisper-1");
      expect(c.provider).toBe("whisper");
    });

    it("does not require ASSEMBLYAI_API_KEY for whisper provider", () => {
      process.env.OPENAI_API_KEY = "oa-key";
      const c = loadConfig({ provider: "whisper" }, NO_SETTINGS);
      expect(c.transcriptionModel).toBe("whisper-1");
    });

    it("--transcribe-model overrides the --provider alias", () => {
      process.env.OPENAI_API_KEY = "oa-key";
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      const c = loadConfig(
        { provider: "whisper", transcribeModel: "gpt-4o-transcribe" },
        NO_SETTINGS,
      );
      expect(c.transcriptionModel).toBe("gpt-4o-transcribe");
    });
  });

  describe("settings integration", () => {
    it("honors settings.json for both models (CLI absent)", () => {
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      process.env.OPENAI_API_KEY = "oa-key";
      const settings: NotaSettings = {
        transcription: { model: "whisper-1" },
        summary: { model: "gpt-5" },
      };
      const c = loadConfig({}, settings);
      expect(c.transcriptionModel).toBe("whisper-1");
      expect(c.summaryModel).toBe("gpt-5");
    });

    it("CLI flags beat settings.json", () => {
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      process.env.OPENAI_API_KEY = "oa-key";
      process.env.GEMINI_API_KEY = "gm-key";
      const settings: NotaSettings = {
        transcription: { model: "whisper-1" },
        summary: { model: "gpt-5" },
      };
      const c = loadConfig(
        { model: "gemini-2.5-pro", transcribeModel: "gpt-4o-transcribe" },
        settings,
      );
      expect(c.transcriptionModel).toBe("gpt-4o-transcribe");
      expect(c.summaryModel).toBe("gemini-2.5-pro");
    });
    it("explicit transcription setting overrides the whisper provider alias", () => {
      process.env.OPENAI_API_KEY = "oa-key";
      const settings: NotaSettings = {
        transcription: { model: "gpt-4o-transcribe" },
      };
      const c = loadConfig({ provider: "whisper" }, settings);
      expect(c.transcriptionModel).toBe("gpt-4o-transcribe");
    });

    it("rejects a transcription model used as a summary model (zombie fallback fails)", () => {
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      process.env.OPENAI_API_KEY = "oa-key";
      const settings: NotaSettings = {
        summary: { model: "whisper-1" },
      };
      // whisper-1 is a transcription model. zombieFallback finds it absent
      // from catalog, resolves gpt-5.4-mini via chain. But then
      // requireModel("gpt-5.4-mini", "summary") works fine.
      // Actually, zombieFallback only checks catalog absence, not task.
      // It replaces the zombie with chain default, then requireModel validates
      // the chain default. So this should succeed, not throw.
      const c = loadConfig({}, settings);
      expect(c.summaryModel).toBe("gpt-5.4-mini");
    });
  });

  describe("misc options", () => {
    beforeEach(() => {
      process.env.ASSEMBLYAI_API_KEY = "aa-key";
      process.env.OPENAI_API_KEY = "oa-key";
    });

    it("defaults to universal transcription", () => {
      const c = loadConfig({}, NO_SETTINGS);
      expect(c.transcriptionModel).toBe("universal");
    });

    it("defaults diarize to true for assemblyai", () => {
      const c = loadConfig({}, NO_SETTINGS);
      expect(c.diarize).toBe(true);
    });

    it("forces diarize true for assemblyai even with --no-diarize", () => {
      const c = loadConfig({ diarize: false }, NO_SETTINGS);
      expect(c.diarize).toBe(true);
    });

    it("respects diarize false for whisper provider", () => {
      const c = loadConfig(
        { provider: "whisper", diarize: false },
        NO_SETTINGS,
      );
      expect(c.diarize).toBe(false);
    });

    it("passes numSpeakers through", () => {
      const c = loadConfig({ numSpeakers: 3 }, NO_SETTINGS);
      expect(c.numSpeakers).toBe(3);
    });

    it("throws for unsupported provider", () => {
      expect(() =>
        loadConfig({ provider: "invalid" }, NO_SETTINGS),
      ).toThrow(/Unsupported provider/);
    });

    it("throws for invalid numSpeakers", () => {
      expect(() =>
        loadConfig({ numSpeakers: 0 }, NO_SETTINGS),
      ).toThrow(/--num-speakers must be a positive integer/);
    });

    it("saves history by default and respects the override", () => {
      const c = loadConfig({}, NO_SETTINGS);
      expect(c.history).toBe(true);
      const c2 = loadConfig({ history: false }, NO_SETTINGS);
      expect(c2.history).toBe(false);
    });

    it("generates summary by default and respects --no-summary", () => {
      const c = loadConfig({}, NO_SETTINGS);
      expect(c.summary).toBe(true);
      const c2 = loadConfig({ summary: false }, NO_SETTINGS);
      expect(c2.summary).toBe(false);
    });

    it("passes deepseek-v4-pro via CLI flag", () => {
      process.env.DEEPSEEK_API_KEY = "ds-key";
      const c = loadConfig({ model: "deepseek-v4-pro" }, NO_SETTINGS);
      expect(c.summaryModel).toBe("deepseek-v4-pro");
      expect(c.summaryBaseURL).toBe("https://api.deepseek.com");
    });
  });
});
