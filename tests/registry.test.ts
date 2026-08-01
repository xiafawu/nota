import { describe, it, expect } from "vitest";
import {
  DEEPSEEK_BASE_URL,
  DEFAULT_SUMMARY_MODEL,
  DEFAULT_TRANSCRIPTION_MODEL,
  GEMINI_OPENAI_BASE_URL,
  getModel,
  isGeminiModel,
  modelsForTask,
  requireModel,
} from "../src/registry.js";

describe("model registry", () => {
  it("derives provider and key env from the model id", () => {
    const universal = getModel("universal")!;
    expect(universal.provider).toBe("assemblyai");
    expect(universal.apiKeyEnv).toBe("ASSEMBLYAI_API_KEY");

    const whisper = getModel("whisper-1")!;
    expect(whisper.provider).toBe("openai");
    expect(whisper.apiKeyEnv).toBe("OPENAI_API_KEY");

    // Summary models come from the baked catalog — verify one is resolvable
    const gpt5mini = getModel("gpt-5-mini")!;
    expect(gpt5mini.task).toBe("summary");
    expect(gpt5mini.provider).toBe("openai");
    expect(gpt5mini.apiKeyEnv).toBe("OPENAI_API_KEY");
  });

  it("routes gemini summary models through the OpenAI-compatible base URL", () => {
    const flash = getModel("gemini-2.5-flash");
    expect(flash).toBeDefined();
    expect(flash!.baseURL).toBe(GEMINI_OPENAI_BASE_URL);
    expect(isGeminiModel("gemini-2.5-pro")).toBe(true);
    expect(isGeminiModel("gpt-5")).toBe(false);
  });

  it("exposes the curated defaults", () => {
    expect(DEFAULT_TRANSCRIPTION_MODEL).toBe("universal-3-5-pro");
    expect(DEFAULT_SUMMARY_MODEL).toBe("gpt-5-mini");
    expect(getModel(DEFAULT_TRANSCRIPTION_MODEL)?.task).toBe("transcription");
    expect(getModel(DEFAULT_SUMMARY_MODEL)?.task).toBe("summary");
  });

  it("lists models per task", () => {
    const t = modelsForTask("transcription").map((m) => m.id);
    const s = modelsForTask("summary").map((m) => m.id);
    // Transcription: slam-1 and nano removed per X1 spec
    expect(t).toEqual([
      "universal-3-5-pro",
      "universal",
      "whisper-1",
      "gpt-4o-transcribe",
      "gpt-4o-mini-transcribe",
    ]);
    // Summary models from baked catalog
    expect(s).toContain("gpt-5-mini");
    expect(s).toContain("gpt-5");
    expect(s).toContain("gpt-5.1");
    expect(s).toContain("gpt-5.4-mini");
    expect(s).toContain("gemini-2.5-flash");
    expect(s).toContain("gemini-2.5-pro");
    expect(s).toContain("deepseek-v4-flash");
    expect(s).toContain("deepseek-v4-pro");
    // The old registry-only ids (gpt-4o, gpt-4.1) are gone from summary
    expect(s).not.toContain("gpt-4o");
    expect(s).not.toContain("gpt-4.1");
  });

  it("routes deepseek summary models through the OpenAI-compatible base URL", () => {
    const dsFlash = getModel("deepseek-v4-flash");
    expect(dsFlash).toBeDefined();
    expect(dsFlash!.baseURL).toBe(DEEPSEEK_BASE_URL);
    expect(dsFlash!.provider).toBe("deepseek");
  });

  it("requireModel rejects unknown ids, listing valid ones", () => {
    expect(() => requireModel("nonexistent", "summary")).toThrow(
      /Unknown summary model.*nonexistent/,
    );
    const msg = tryRequire("nonexistent", "summary");
    // Should mention at least one valid summary model
    expect(msg).toContain("gpt-5-mini");
    expect(msg).toContain("Valid summary models");
  });

  it("requireModel rejects a model used for the wrong task", () => {
    expect(() => requireModel("universal", "summary")).toThrow(
      /is a transcription model/,
    );
  });

  it("returns undefined for nonexistent model via getModel", () => {
    expect(getModel("does-not-exist")).toBeUndefined();
  });

  it("resolves a new catalog-added model like gpt-5.6", () => {
    const m = getModel("gpt-5.6");
    expect(m).toBeDefined();
    expect(m!.task).toBe("summary");
    expect(m!.provider).toBe("openai");
  });

  it("resolves gemini-3.6-flash from the baked catalog", () => {
    const m = getModel("gemini-3.6-flash");
    expect(m).toBeDefined();
    expect(m!.provider).toBe("gemini");
    expect(m!.baseURL).toBe(GEMINI_OPENAI_BASE_URL);
  });
});

function tryRequire(id: string, task: "summary"): string {
  try {
    requireModel(id, task);
    return "";
  } catch (e) {
    return (e as Error).message;
  }
}
