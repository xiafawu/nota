import { describe, it, expect } from "vitest";
import { perModelSummary, perRunLog } from "../src/usage-stats.js";
import type { HistoryRecord } from "../src/pipeline/history.js";
import type { Provider } from "../src/config.js";

const ASSEMBLYAI = "assemblyai" as Provider;
const WHISPER = "whisper" as Provider;

/** Minimal record without usage — simulates pre-feature history files. */
function legacyRecord(
  overrides: Partial<HistoryRecord> = {},
): HistoryRecord {
  return {
    id: "legacy-001",
    createdAt: "2026-07-01T00:00:00.000Z",
    updatedAt: "2026-07-01T00:00:00.000Z",
    capturedAt: null,
    sourcePath: "/tmp/test.m4a",
    sourceName: "test.m4a",
    provider: ASSEMBLYAI,
    options: { diarize: true, identify: false, model: "gpt-5-mini" },
    durationMinutes: 30,
    transcriptText: "hello world",
    segments: [],
    status: "completed",
    summary: {
      title: "Test",
      tags: [],
      narrative: "",
      keyTopics: [],
      decisions: [],
      actionItems: [],
    },
    outputPath: "/tmp/out.md",
    ...overrides,
  };
}

/** Record with usage entries populated. */
function recordWithUsage(
  overrides: Partial<HistoryRecord> = {},
): HistoryRecord {
  return {
    ...legacyRecord(),
    id: "usage-001",
    createdAt: "2026-07-10T00:00:00.000Z",
    usage: [
      {
        modelId: "whisper-1",
        task: "transcription",
        provider: WHISPER,
        calls: 1,
        durationMin: 5,
        costUSD: 0.03,
        estimated: false,
      },
      {
        modelId: "gpt-5-mini",
        task: "summary",
        provider: WHISPER,
        calls: 3,
        tokensIn: 150_000,
        tokensOut: 10_000,
        costUSD: 0.2375,
        estimated: false,
      },
    ],
    ...overrides,
  };
}

describe("perModelSummary", () => {
  it("returns empty array for empty records", () => {
    const result = perModelSummary([]);
    expect(result).toEqual([]);
  });

  it("aggregates legacy records with estimated cost", () => {
    const records = [legacyRecord({ provider: ASSEMBLYAI, durationMinutes: 60 })];
    const result = perModelSummary(records);
    // AssemblyAI $0.15/hr = $0.0025/min, 60 min = $0.15
    const universal = result.find((r) => r.modelId === "universal");
    expect(universal).toBeDefined();
    expect(universal!.costUSD).toBeCloseTo(0.15, 5);
    expect(universal!.runs).toBe(1);
    expect(universal!.hasUnknown).toBe(false);

    // Legacy summary row
    const summaryRow = result.find((r) => r.modelId === "summary");
    expect(summaryRow).toBeDefined();
    expect(summaryRow!.hasUnknown).toBe(true);
    expect(summaryRow!.costUSD).toBe(0);
  });

  it("aggregates records with usage entries", () => {
    const records = [recordWithUsage()];
    const result = perModelSummary(records);

    const whisper = result.find((r) => r.modelId === "whisper-1");
    expect(whisper).toBeDefined();
    expect(whisper!.runs).toBe(1);
    expect(whisper!.calls).toBe(1);
    expect(whisper!.costUSD).toBeCloseTo(0.03, 5);

    const gpt5mini = result.find((r) => r.modelId === "gpt-5-mini");
    expect(gpt5mini).toBeDefined();
    expect(gpt5mini!.runs).toBe(1);
    expect(gpt5mini!.calls).toBe(3);
    expect(gpt5mini!.costUSD).toBeCloseTo(0.2375, 5);
  });

  it("sorts by cost descending", () => {
    const records = [
      recordWithUsage({
        id: "a",
        usage: [
          {
            modelId: "gpt-5",
            task: "summary" as const,
            provider: WHISPER,
            calls: 1,
            tokensIn: 100_000,
            tokensOut: 10_000,
            costUSD: 0.225,
            estimated: false,
          },
        ],
      }),
      recordWithUsage({
        id: "b",
        usage: [
          {
            modelId: "whisper-1",
            task: "transcription" as const,
            provider: WHISPER,
            calls: 1,
            durationMin: 60,
            costUSD: 0.36,
            estimated: false,
          },
        ],
      }),
    ];
    const result = perModelSummary(records);
    expect(result[0].costUSD).toBeGreaterThanOrEqual(result[1].costUSD);
  });

  it("flags hasUnknown when costUSD is null", () => {
    const records = [
      recordWithUsage({
        usage: [
          {
            modelId: "unknown-model",
            task: "summary" as const,
            provider: WHISPER,
            calls: 1,
            tokensIn: 100,
            tokensOut: 50,
            costUSD: null,
            estimated: false,
          },
        ],
      }),
    ];
    const result = perModelSummary(records);
    expect(result[0].hasUnknown).toBe(true);
    expect(result[0].costUSD).toBe(0);
  });

  it("applies window filter — includes records within 30 days", () => {
    const recent = legacyRecord({
      id: "recent",
      createdAt: new Date().toISOString(),
    });
    const result = perModelSummary([recent], "30d");
    expect(result.length).toBeGreaterThan(0);
  });

  it("applies window filter — excludes old records", () => {
    const old = legacyRecord({
      id: "old",
      createdAt: "2024-01-01T00:00:00.000Z",
    });
    const result = perModelSummary([old], "30d");
    expect(result).toEqual([]);
  });

  it("handles mixed legacy and new records", () => {
    const records = [
      legacyRecord({ id: "l1", provider: ASSEMBLYAI, durationMinutes: 10 }),
      recordWithUsage({ id: "n1" }),
    ];
    const result = perModelSummary(records);
    // 2 transcription rows + 2 summary rows
    expect(result.length).toBeGreaterThanOrEqual(3);
    // The new record's summary should be present
    const gpt5mini = result.find((r) => r.modelId === "gpt-5-mini");
    expect(gpt5mini).toBeDefined();
  });
});

describe("perRunLog", () => {
  it("returns empty array for empty records", () => {
    expect(perRunLog([])).toEqual([]);
  });

  it("returns rows sorted by newest first", () => {
    const old = legacyRecord({ id: "old", createdAt: "2026-06-01T00:00:00.000Z" });
    const recent = legacyRecord({ id: "recent", createdAt: "2026-07-10T00:00:00.000Z" });
    const result = perRunLog([old, recent]);
    expect(result[0].id).toBe("recent");
    expect(result[1].id).toBe("old");
  });

  it("reclaims transcription cost for legacy records", () => {
    const record = legacyRecord({ provider: ASSEMBLYAI, durationMinutes: 60 });
    const result = perRunLog([record]);
    expect(result).toHaveLength(1);
    // AssemblyAI $0.15/hr = $0.0025/min, 60 min = $0.15
    expect(result[0].totalCostUSD).toBeCloseTo(0.15, 5);
    expect(result[0].models).toEqual(["universal"]);
  });

  it("computes total cost from usage entries", () => {
    const record = recordWithUsage();
    const result = perRunLog([record]);
    expect(result).toHaveLength(1);
    // 0.03 (whisper-1) + 0.2375 (gpt-5-mini) = 0.2675
    expect(result[0].totalCostUSD).toBeCloseTo(0.2675, 5);
    expect(result[0].models).toContain("whisper-1");
    expect(result[0].models).toContain("gpt-5-mini");
  });

  it("returns null totalCostUSD when any cost is unknown", () => {
    const record = recordWithUsage({
      usage: [
        {
          modelId: "unknown-model",
          task: "summary" as const,
          provider: WHISPER,
          calls: 1,
          tokensIn: 100,
          tokensOut: 50,
          costUSD: null,
          estimated: false,
        },
      ],
    });
    const result = perRunLog([record]);
    expect(result[0].totalCostUSD).toBeNull();
  });

  it("excludes null costs from perRunLog total but flags null", () => {
    const record = recordWithUsage({
      usage: [
        {
          modelId: "whisper-1",
          task: "transcription" as const,
          provider: WHISPER,
          calls: 1,
          durationMin: 10,
          costUSD: 0.06,
          estimated: false,
        },
        {
          modelId: "unknown-model",
          task: "summary" as const,
          provider: WHISPER,
          calls: 1,
          tokensIn: 100,
          tokensOut: 50,
          costUSD: null,
          estimated: false,
        },
      ],
    });
    const result = perRunLog([record]);
    // Has unknown → null total
    expect(result[0].totalCostUSD).toBeNull();
    expect(result[0].models).toContain("whisper-1");
  });
});
