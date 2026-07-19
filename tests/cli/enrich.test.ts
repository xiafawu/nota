import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// Mock the generation calls so no OpenAI/Gemini request is ever made. The rest
// of the summarize module (prompt builders, parsers) is preserved via
// importActual so the factory does not blank it out.
vi.mock("../../src/pipeline/summarize.js", async (importActual) => ({
  ...(await importActual<typeof import("../../src/pipeline/summarize.js")>()),
  summarizeTranscript: vi.fn(),
  summarizeOnly: vi.fn(),
  generateTags: vi.fn(),
}));

import {
  EnrichError,
  applyEnrichment,
  parseEnrichmentPayload,
  summarizeRecord,
  tagRecord,
} from "../../src/cli/enrich.js";
import {
  generateTags,
  summarizeOnly,
  summarizeTranscript,
} from "../../src/pipeline/summarize.js";
import {
  applyEnrichmentToRecord,
  createHistoryRecord,
  loadHistoryRecord,
} from "../../src/pipeline/history.js";
import type { CreateHistoryInput } from "../../src/pipeline/history.js";
import type { MeetingSummary } from "../../src/pipeline/summarize.js";

const GENERATED_SUMMARY: MeetingSummary = {
  title: "Enriched Meeting",
  tags: ["generated"],
  narrative: "A freshly generated summary.",
  keyTopics: ["**Topic A** — details"],
  decisions: [],
  actionItems: [],
};

function transcribedInput(
  overrides: Partial<CreateHistoryInput> = {},
): CreateHistoryInput {
  return {
    sourcePath: "/tmp/meeting.m4a",
    provider: "assemblyai",
    options: { diarize: true, identify: false, model: "gpt-4o" },
    durationMinutes: 10,
    transcriptText: "Hello from the saved transcript.",
    segments: [{ start: 0, end: 2, text: "Hello", speaker: "Speaker 1" }],
    ...overrides,
  };
}

let historyDir: string;
let outputPath: string;
let originalApiKey: string | undefined;
let originalSettingsFile: string | undefined;
let stderrSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  historyDir = mkdtempSync(path.join(tmpdir(), "nota-enrich-"));
  outputPath = path.join(historyDir, "out.summary.md");
  originalApiKey = process.env.OPENAI_API_KEY;
  process.env.OPENAI_API_KEY = "test-key";
  // Keep the resolved summary model hermetic (the built-in default) even when
  // the developer's real ~/.nota/settings.json configures something else.
  originalSettingsFile = process.env.NOTA_SETTINGS_FILE;
  process.env.NOTA_SETTINGS_FILE = path.join(historyDir, "no-settings.json");
  vi.mocked(summarizeTranscript).mockReset().mockResolvedValue({
    summary: { ...GENERATED_SUMMARY, tags: [...GENERATED_SUMMARY.tags] },
    tokenUsage: { calls: 1, tokensIn: 500, tokensOut: 200 },
  });
  vi.mocked(summarizeOnly).mockReset().mockResolvedValue({
    summary: { ...GENERATED_SUMMARY, tags: [] },
    tokenUsage: { calls: 1, tokensIn: 400, tokensOut: 150 },
  });
  vi.mocked(generateTags).mockReset().mockResolvedValue({
    tags: ["planning", "roadmap"],
    tokenUsage: { calls: 1, tokensIn: 100, tokensOut: 10 },
  });
  stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
});

afterEach(() => {
  stderrSpy.mockRestore();
  if (originalApiKey === undefined) {
    delete process.env.OPENAI_API_KEY;
  } else {
    process.env.OPENAI_API_KEY = originalApiKey;
  }
  if (originalSettingsFile === undefined) {
    delete process.env.NOTA_SETTINGS_FILE;
  } else {
    process.env.NOTA_SETTINGS_FILE = originalSettingsFile;
  }
  rmSync(historyDir, { recursive: true, force: true });
});

describe("summarizeRecord", () => {
  it("summarizes a transcribed record, completes it, and rewrites the markdown", async () => {
    const record = await createHistoryRecord(
      transcribedInput({ outputPath }),
      historyDir,
    );

    const updated = await summarizeRecord(record.id, { historyDir });

    expect(updated.status).toBe("completed");
    expect(updated.summary?.narrative).toBe("A freshly generated summary.");
    expect(updated.summaryEdited).toBe(false);
    // Usage entry captured through makeSummaryUsage (task "summary").
    expect(updated.usage).toHaveLength(1);
    expect(updated.usage?.[0].task).toBe("summary");
    expect(updated.usage?.[0].modelId).toBe("gpt-5-mini");
    // The .md was rewritten from the record.
    expect(readFileSync(outputPath, "utf-8")).toContain("Enriched Meeting");
    // Persisted, not just returned.
    const loaded = await loadHistoryRecord(record.id, historyDir);
    expect(loaded.status).toBe("completed");
  });

  it("exits 2 when the summary was hand-edited and --force is absent", async () => {
    const record = await createHistoryRecord(transcribedInput(), historyDir);
    await applyEnrichmentToRecord(
      record.id,
      { summary: "Hand-edited.", summaryEdited: true },
      historyDir,
    );

    const error = await summarizeRecord(record.id, { historyDir }).then(
      () => null,
      (err) => err,
    );
    expect(error).toBeInstanceOf(EnrichError);
    expect((error as EnrichError).exitCode).toBe(2);
    expect(summarizeTranscript).not.toHaveBeenCalled();
    expect(summarizeOnly).not.toHaveBeenCalled();

    // Record untouched.
    const loaded = await loadHistoryRecord(record.id, historyDir);
    expect(loaded.summary?.narrative).toBe("Hand-edited.");
  });

  it("regenerates over an edited summary with --force and clears the flag", async () => {
    const record = await createHistoryRecord(
      transcribedInput({ outputPath }),
      historyDir,
    );
    await applyEnrichmentToRecord(
      record.id,
      { summary: "Hand-edited.", summaryEdited: true },
      historyDir,
    );

    const updated = await summarizeRecord(record.id, { historyDir, force: true });
    expect(updated.summary?.narrative).toBe("A freshly generated summary.");
    expect(updated.summaryEdited).toBe(false);
  });

  it("uses the summary-only prompt and keeps tags verbatim when tags are edited", async () => {
    const record = await createHistoryRecord(
      transcribedInput({ outputPath }),
      historyDir,
    );
    await applyEnrichmentToRecord(
      record.id,
      { tags: ["my-tag", "another"], tagsEdited: true },
      historyDir,
    );

    const updated = await summarizeRecord(record.id, { historyDir });

    expect(summarizeOnly).toHaveBeenCalledTimes(1);
    expect(summarizeTranscript).not.toHaveBeenCalled();
    // Edited tags are untouched and still protected.
    expect(updated.summary?.tags).toEqual(["my-tag", "another"]);
    expect(updated.tagsEdited).toBe(true);
  });

  it("throws without touching the record when the model returns an empty narrative", async () => {
    vi.mocked(summarizeTranscript).mockResolvedValue({
      summary: { ...GENERATED_SUMMARY, narrative: "   " },
      tokenUsage: { calls: 1, tokensIn: 500, tokensOut: 0 },
    });
    const record = await createHistoryRecord(transcribedInput(), historyDir);

    await expect(summarizeRecord(record.id, { historyDir })).rejects.toThrow(
      /empty summary/,
    );
    const loaded = await loadHistoryRecord(record.id, historyDir);
    expect(loaded.status).toBe("transcribed");
    expect(loaded.summary).toBeUndefined();
  });
});

describe("tagRecord", () => {
  it("merges generated tags after existing ones and leaves status untouched", async () => {
    const record = await createHistoryRecord(
      transcribedInput({ outputPath }),
      historyDir,
    );
    await applyEnrichmentToRecord(record.id, { tags: ["ops", "Roadmap"] }, historyDir);

    const updated = await tagRecord(record.id, { historyDir });

    // Union, existing-first, case-insensitive dedup ("Roadmap" vs "roadmap").
    expect(updated.summary?.tags).toEqual(["ops", "roadmap", "planning"]);
    expect(updated.status).toBe("transcribed");
    expect(updated.usage?.[0].task).toBe("summary");
    // Tags line lands in the rewritten markdown.
    expect(readFileSync(outputPath, "utf-8")).toContain(
      "**Tags:** ops, roadmap, planning",
    );
  });

  it("exits 2 when tags were hand-edited and --force is absent", async () => {
    const record = await createHistoryRecord(transcribedInput(), historyDir);
    await applyEnrichmentToRecord(
      record.id,
      { tags: ["manual"], tagsEdited: true },
      historyDir,
    );

    const error = await tagRecord(record.id, { historyDir }).then(
      () => null,
      (err) => err,
    );
    expect(error).toBeInstanceOf(EnrichError);
    expect((error as EnrichError).exitCode).toBe(2);
    expect(generateTags).not.toHaveBeenCalled();
  });

  it("with --force merges rather than replaces, so manual tags survive", async () => {
    const record = await createHistoryRecord(
      transcribedInput({ outputPath }),
      historyDir,
    );
    await applyEnrichmentToRecord(
      record.id,
      { tags: ["manual"], tagsEdited: true },
      historyDir,
    );

    const updated = await tagRecord(record.id, { historyDir, force: true });
    expect(updated.summary?.tags).toEqual(["manual", "planning", "roadmap"]);
    // Still flagged edited: the set still contains manual tags, so a full
    // summary regeneration must keep protecting them.
    expect(updated.tagsEdited).toBe(true);
  });

  it("tags from the summary text when one exists (E1 ladder rung 1)", async () => {
    const record = await createHistoryRecord(
      transcribedInput({ outputPath }),
      historyDir,
    );
    await summarizeRecord(record.id, { historyDir });
    vi.mocked(generateTags).mockClear();

    await tagRecord(record.id, { historyDir });

    const input = vi.mocked(generateTags).mock.calls[0][0];
    expect(input).toContain("A freshly generated summary.");
    expect(input).toContain("**Topic A** — details");
    expect(input).not.toContain("Hello from the saved transcript.");
  });

  it("tags from the whole transcript when there is no summary (rung 2)", async () => {
    const record = await createHistoryRecord(transcribedInput(), historyDir);

    await tagRecord(record.id, { historyDir });

    expect(vi.mocked(generateTags).mock.calls[0][0]).toBe(
      "Hello from the saved transcript.",
    );
  });
});

describe("applyEnrichment", () => {
  it("applies the patch record-first: a failed .md rewrite warns but keeps the record", async () => {
    const record = await createHistoryRecord(
      // outputPath in a directory that does not exist → writeFile fails.
      transcribedInput({
        outputPath: path.join(historyDir, "missing-dir", "out.summary.md"),
      }),
      historyDir,
    );

    const updated = await applyEnrichment(
      record.id,
      { summary: "Edited narrative.", summaryEdited: true },
      { historyDir },
    );

    // Record write happened despite the failed export (record first, E3-f).
    expect(updated.summary?.narrative).toBe("Edited narrative.");
    expect(updated.summaryEdited).toBe(true);
    const loaded = await loadHistoryRecord(record.id, historyDir);
    expect(loaded.summary?.narrative).toBe("Edited narrative.");
    // The failure surfaced as a stderr warning, not an error.
    expect(
      stderrSpy.mock.calls.some(([line]) =>
        String(line).includes("failed to rewrite markdown"),
      ),
    ).toBe(true);
  });

  it("rewrites the .md from the record on success", async () => {
    const record = await createHistoryRecord(
      transcribedInput({ outputPath }),
      historyDir,
    );

    await applyEnrichment(
      record.id,
      { summary: "Edited narrative.", summaryEdited: true },
      { historyDir },
    );

    expect(existsSync(outputPath)).toBe(true);
    expect(readFileSync(outputPath, "utf-8")).toContain("Edited narrative.");
  });

  it("resolves a unique id prefix like the other history verbs", async () => {
    const record = await createHistoryRecord(transcribedInput(), historyDir);

    const updated = await applyEnrichment(
      record.id.slice(0, -1),
      { tags: ["prefixed"], tagsEdited: true },
      { historyDir },
    );
    expect(updated.id).toBe(record.id);
    expect(updated.summary?.tags).toEqual(["prefixed"]);
  });
});

describe("parseEnrichmentPayload", () => {
  it("accepts the full payload shape", () => {
    expect(
      parseEnrichmentPayload(
        JSON.stringify({
          summary: "text",
          tags: ["a", "b"],
          summaryEdited: true,
          tagsEdited: false,
        }),
      ),
    ).toEqual({
      summary: "text",
      tags: ["a", "b"],
      summaryEdited: true,
      tagsEdited: false,
    });
  });

  it("accepts a partial payload", () => {
    expect(parseEnrichmentPayload('{"tagsEdited": true}')).toEqual({
      tagsEdited: true,
    });
  });

  it.each([
    ["not json", /not valid JSON/],
    ['["array"]', /must be a JSON object/],
    ['{"summary": 42}', /summary must be a string/],
    ['{"tags": "planning"}', /tags must be an array of strings/],
    ['{"tags": ["ok", 1]}', /tags must be an array of strings/],
    ['{"summaryEdited": "yes"}', /summaryEdited must be a boolean/],
  ])("rejects malformed payload %s", (raw, message) => {
    expect(() => parseEnrichmentPayload(raw)).toThrow(message);
  });
});
