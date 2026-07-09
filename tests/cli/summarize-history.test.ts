import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// Mock the summarize module so no OpenAI/Gemini request is ever made. Only
// summarizeTranscript is stubbed; the rest of the module (e.g. the pure
// isGeminiModel used for provider routing) is preserved via importActual so the
// factory does not blank it out. The factory is hoisted above the imports below
// by vitest, so summarizeHistory picks up the spy rather than the real call.
vi.mock("../../src/pipeline/summarize.js", async (importActual) => ({
  ...(await importActual<typeof import("../../src/pipeline/summarize.js")>()),
  summarizeTranscript: vi.fn(),
}));

import { summarizeHistory } from "../../src/cli/summarize-history.js";
import { summarizeTranscript } from "../../src/pipeline/summarize.js";
import {
  completeHistoryRecord,
  createHistoryRecord,
  loadHistoryRecord,
} from "../../src/pipeline/history.js";
import type { CreateHistoryInput } from "../../src/pipeline/history.js";
import type { MeetingSummary } from "../../src/pipeline/summarize.js";

const FIXED_SUMMARY: MeetingSummary = {
  title: "Recovered Meeting",
  tags: ["recovery"],
  narrative: "A recovered summary.",
  keyTopics: ["**Topic A** — details"],
  decisions: ["Ship the fix"],
  actionItems: ["[ ] Do the thing — assigned to Alice"],
};

const TRANSCRIPT = "Hello from the saved transcript.";

function transcribedInput(
  overrides: Partial<CreateHistoryInput> = {},
): CreateHistoryInput {
  return {
    sourcePath: "/tmp/meeting.m4a",
    provider: "assemblyai",
    options: { diarize: true, identify: false, model: "gpt-4o" },
    durationMinutes: 10,
    transcriptText: TRANSCRIPT,
    segments: [{ start: 0, end: 2, text: "Hello", speaker: "Speaker 1" }],
    capturedAt: "2026-01-02T03:04:05.000Z",
    ...overrides,
  };
}

let historyDir: string;
let outputPath: string;
let originalApiKey: string | undefined;
let originalGeminiKey: string | undefined;
let stderrSpy: ReturnType<typeof vi.spyOn>;

function restoreKey(name: string, original: string | undefined): void {
  if (original === undefined) {
    delete process.env[name];
  } else {
    process.env[name] = original;
  }
}

beforeEach(() => {
  historyDir = mkdtempSync(path.join(tmpdir(), "nota-summarize-history-"));
  outputPath = path.join(historyDir, "out.summary.md");
  originalApiKey = process.env.OPENAI_API_KEY;
  originalGeminiKey = process.env.GEMINI_API_KEY;
  vi.mocked(summarizeTranscript).mockReset();
  vi.mocked(summarizeTranscript).mockResolvedValue(FIXED_SUMMARY);
  stderrSpy = vi
    .spyOn(process.stderr, "write")
    .mockImplementation(() => true);
});

afterEach(() => {
  stderrSpy.mockRestore();
  restoreKey("OPENAI_API_KEY", originalApiKey);
  restoreKey("GEMINI_API_KEY", originalGeminiKey);
  rmSync(historyDir, { recursive: true, force: true });
});

describe("summarizeHistory", () => {
  it("summarizes a transcribed record and marks it completed", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    const record = await createHistoryRecord(transcribedInput(), historyDir);
    expect(record.status).toBe("transcribed");

    const result = await summarizeHistory(record.id, {
      historyDir,
      output: outputPath,
    });

    // Output markdown was written.
    expect(result).toBe(outputPath);
    expect(existsSync(outputPath)).toBe(true);
    expect(readFileSync(outputPath, "utf-8")).toContain("Recovered Meeting");

    // Record is now completed with the summary persisted.
    const updated = await loadHistoryRecord(record.id, historyDir);
    expect(updated.status).toBe("completed");
    expect(updated.summary?.narrative).toBe("A recovered summary.");
    expect(updated.outputPath).toBe(outputPath);

    // The transcript text was handed to the summarizer exactly once.
    expect(summarizeTranscript).toHaveBeenCalledTimes(1);
    expect(vi.mocked(summarizeTranscript).mock.calls[0][0]).toBe(TRANSCRIPT);
  });

  it("does not call OpenAI when already completed without --force", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    const record = await createHistoryRecord(transcribedInput(), historyDir);
    await completeHistoryRecord(
      record.id,
      { summary: FIXED_SUMMARY, outputPath: "/tmp/existing.summary.md" },
      historyDir,
    );

    const result = await summarizeHistory(record.id, { historyDir });

    expect(result).toBe("/tmp/existing.summary.md");
    expect(summarizeTranscript).not.toHaveBeenCalled();
  });

  it("re-summarizes a completed record when --force is set", async () => {
    process.env.OPENAI_API_KEY = "test-key";
    const record = await createHistoryRecord(transcribedInput(), historyDir);
    await completeHistoryRecord(
      record.id,
      { summary: FIXED_SUMMARY, outputPath: "/tmp/existing.summary.md" },
      historyDir,
    );

    const result = await summarizeHistory(record.id, {
      historyDir,
      output: outputPath,
      force: true,
    });

    expect(result).toBe(outputPath);
    expect(summarizeTranscript).toHaveBeenCalledTimes(1);
  });

  it("routes gemini-* models to GEMINI_API_KEY", async () => {
    delete process.env.OPENAI_API_KEY; // prove it does not fall back to OpenAI
    process.env.GEMINI_API_KEY = "gem-key";
    const record = await createHistoryRecord(transcribedInput(), historyDir);

    const result = await summarizeHistory(record.id, {
      historyDir,
      output: outputPath,
      model: "gemini-2.5-flash",
    });

    expect(result).toBe(outputPath);
    expect(summarizeTranscript).toHaveBeenCalledTimes(1);
    // Provider routing: apiKey (arg 2) is the Gemini key, model (arg 3) is passed through.
    const call = vi.mocked(summarizeTranscript).mock.calls[0];
    expect(call[1]).toBe("gem-key");
    expect(call[2]).toBe("gemini-2.5-flash");
  });

  it("rejects with a helpful error when GEMINI_API_KEY is missing for a gemini model", async () => {
    delete process.env.OPENAI_API_KEY;
    delete process.env.GEMINI_API_KEY;
    const record = await createHistoryRecord(transcribedInput(), historyDir);

    await expect(
      summarizeHistory(record.id, {
        historyDir,
        output: outputPath,
        model: "gemini-2.5-flash",
      }),
    ).rejects.toThrow(/GEMINI_API_KEY environment variable is required/);
    expect(summarizeTranscript).not.toHaveBeenCalled();
  });

  it("rejects with a helpful error when OPENAI_API_KEY is missing", async () => {
    delete process.env.OPENAI_API_KEY;
    const record = await createHistoryRecord(transcribedInput(), historyDir);

    await expect(
      summarizeHistory(record.id, { historyDir, output: outputPath }),
    ).rejects.toThrow(/OPENAI_API_KEY environment variable is required/);
    expect(summarizeTranscript).not.toHaveBeenCalled();
  });
});
