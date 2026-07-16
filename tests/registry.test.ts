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
    expect(getModel("universal")).toMatchObject({
      task: "transcription",
      provider: "assemblyai",
      apiKeyEnv: "ASSEMBLYAI_API_KEY",
    });
    expect(getModel("whisper-1")).toMatchObject({
      provider: "openai",
      apiKeyEnv: "OPENAI_API_KEY",
    });
    expect(getModel("gpt-5-mini")).toMatchObject({
      task: "summary",
      provider: "openai",
      apiKeyEnv: "OPENAI_API_KEY",
    });
  });

  it("routes gemini summary models through the OpenAI-compatible base URL", () => {
    const flash = getModel("gemini-2.5-flash");
    expect(flash).toMatchObject({
      provider: "gemini",
      apiKeyEnv: "GEMINI_API_KEY",
      baseURL: GEMINI_OPENAI_BASE_URL,
    });
    expect(isGeminiModel("gemini-2.5-pro")).toBe(true);
    expect(isGeminiModel("gpt-4o")).toBe(false);
  });

  it("exposes the curated defaults", () => {
    expect(DEFAULT_TRANSCRIPTION_MODEL).toBe("universal");
    expect(DEFAULT_SUMMARY_MODEL).toBe("gpt-5-mini");
    expect(getModel(DEFAULT_TRANSCRIPTION_MODEL)?.task).toBe("transcription");
    expect(getModel(DEFAULT_SUMMARY_MODEL)?.task).toBe("summary");
  });

  it("lists models per task", () => {
    const t = modelsForTask("transcription").map((m) => m.id);
    const s = modelsForTask("summary").map((m) => m.id);
    expect(t).toEqual([
      "universal",
      "slam-1",
      "nano",
      "whisper-1",
      "gpt-4o-transcribe",
      "gpt-4o-mini-transcribe",
    ]);
    expect(s).toEqual([
      "gpt-5-mini",
      "gpt-5",
      "gpt-4o",
      "gpt-4.1",
      "gemini-2.5-flash",
      "gemini-2.5-pro",
      "deepseek-v4-flash",
      "deepseek-v4-pro",
    ]);
  });

  it("routes deepseek summary models through the OpenAI-compatible base URL", () => {
    expect(getModel("deepseek-v4-flash")).toMatchObject({
      task: "summary",
      provider: "deepseek",
      apiKeyEnv: "DEEPSEEK_API_KEY",
      baseURL: DEEPSEEK_BASE_URL,
    });
    expect(getModel("deepseek-v4-pro")).toMatchObject({
      provider: "deepseek",
      apiKeyEnv: "DEEPSEEK_API_KEY",
      baseURL: DEEPSEEK_BASE_URL,
    });
    expect(isGeminiModel("deepseek-v4-flash")).toBe(false);
  });

  it("requireModel rejects unknown ids, listing valid ones", () => {
    expect(() => requireModel("nope", "summary")).toThrow(
      /Unknown summary model: nope\. Valid summary models: /,
    );
  });

  it("requireModel rejects a model used for the wrong task", () => {
    expect(() => requireModel("universal", "summary")).toThrow(
      /is a transcription model, not a summary model/,
    );
    expect(() => requireModel("gpt-4o", "transcription")).toThrow(
      /is a summary model, not a transcription model/,
    );
  });
});
