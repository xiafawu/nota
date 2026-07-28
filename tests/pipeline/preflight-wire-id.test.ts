import { beforeEach, describe, expect, it, vi } from "vitest";

// Preflight is the blocking gate in front of a paid transcription, so what it
// puts on the wire has to be exactly what the real summary call would. Every
// outbound leg is stubbed: this file is about the *arguments*, not the network.
vi.mock("../../src/pipeline/summarize.js", async (importActual) => ({
  ...(await importActual<typeof import("../../src/pipeline/summarize.js")>()),
  canarySummaryModel: vi.fn(),
}));
vi.mock("../../src/pipeline/assemblyai.js", () => ({
  canaryAssemblyAI: vi.fn(async () => undefined),
}));
vi.mock("../../src/utils/ffmpeg.js", () => ({
  checkFfmpeg: vi.fn(async () => undefined),
}));
vi.mock("../../src/pipeline/embed.js", () => ({
  isIdentityAvailable: vi.fn(async () => false),
}));

import { runPreflight } from "../../src/pipeline/preflight.js";
import { canarySummaryModel } from "../../src/pipeline/summarize.js";
import { OPENROUTER_BASE_URL } from "../../src/openrouter.js";
import { requireModel } from "../../src/registry.js";
import type { AppConfig } from "../../src/config.js";

const SONNET = "openrouter/anthropic/claude-sonnet-5";

function configFor(summaryModel: string): AppConfig {
  const entry = requireModel(summaryModel, "summary");
  return {
    provider: "assemblyai",
    transcriptionModel: "universal",
    summaryModel: entry.id,
    summaryWireModel: entry.wireId,
    transcriptionApiKey: "aai-key",
    summaryApiKey: "summary-key",
    summaryBaseURL: entry.baseURL,
    verbose: false,
    diarize: true,
    summary: true,
    identify: false,
    history: false,
    force: false,
    skipPreflight: false,
    verifySpeakers: false,
  };
}

beforeEach(() => {
  vi.mocked(canarySummaryModel).mockReset().mockResolvedValue(undefined);
});

describe("the summary canary", () => {
  it("sends the wire id for a namespaced model, not the canonical one", async () => {
    const result = await runPreflight(configFor(SONNET));

    expect(canarySummaryModel).toHaveBeenCalledWith(
      "summary-key",
      "anthropic/claude-sonnet-5",
      OPENROUTER_BASE_URL,
    );
    // The canonical id is still what the user is shown — only the wire differs.
    const summary = result.checks.find((c) => c.id === "summary")!;
    expect(summary.status).toBe("ok");
    expect(summary.label).toContain("Claude Sonnet 5");

    // The whole point: a namespaced summary model does not block the run.
    expect(result.overall).toBe("ready");
  });

  it("sends a flat id unchanged", async () => {
    await runPreflight(configFor("gpt-5-mini"));
    expect(canarySummaryModel).toHaveBeenCalledWith("summary-key", "gpt-5-mini", undefined);
  });
});
