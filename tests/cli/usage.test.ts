import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import type { HistoryRecord, UsageEntry } from "../../src/pipeline/history.js";
import { parseWindow, usageRuns, usageSummary, usageSummaryJSON } from "../../src/cli/usage.js";

let dir: string;
let stdout: string[];
let stderr: string[];
let stdoutSpy: ReturnType<typeof vi.spyOn>;
let stderrSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  dir = mkdtempSync(path.join(tmpdir(), "nota-usage-cli-"));
  stdout = [];
  stderr = [];
  stdoutSpy = vi.spyOn(process.stdout, "write").mockImplementation((chunk) => {
    stdout.push(String(chunk));
    return true;
  });
  stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation((chunk) => {
    stderr.push(String(chunk));
    return true;
  });
});

afterEach(() => {
  stdoutSpy.mockRestore();
  stderrSpy.mockRestore();
  rmSync(dir, { recursive: true, force: true });
});

/** Write a history JSON file into the test dir. */
function writeRecord(record: HistoryRecord): void {
  writeFileSync(
    path.join(dir, `${record.id}.json`),
    JSON.stringify(record),
    "utf-8",
  );
}

// ── Fixtures ──────────────────────────────────────────────

const baseRecord = {
  createdAt: "2026-07-15T12:00:00.000Z",
  updatedAt: "2026-07-15T12:01:00.000Z",
  capturedAt: null,
  sourcePath: "/tmp/test.m4a",
  sourceName: "test.m4a",
  durationMinutes: 5,
  transcriptText: "hello world",
  segments: [],
  status: "completed" as const,
  provider: "assemblyai" as const,
  options: { model: "gpt-4o" },
};

function recordWithUsage(
  id: string,
  usage: UsageEntry[],
  overrides: Partial<HistoryRecord> = {},
): HistoryRecord {
  return {
    ...baseRecord,
    id,
    usage,
    ...overrides,
  } as HistoryRecord;
}

// ── parseWindow ──────────────────────────────────────────

describe("parseWindow", () => {
  it("accepts all", () => {
    expect(parseWindow("all")).toBe("all");
  });

  it("accepts 30d", () => {
    expect(parseWindow("30d")).toBe("30d");
  });

  it("accepts month", () => {
    expect(parseWindow("month")).toBe("month");
  });

  it("is case-insensitive", () => {
    expect(parseWindow("ALL")).toBe("all");
    expect(parseWindow("Month")).toBe("month");
  });

  it("throws on invalid window", () => {
    expect(() => parseWindow("forever")).toThrow(
      'Invalid window: "forever". Valid values: all, 30d, month',
    );
  });
});

// ── usageSummary ──────────────────────────────────────────

describe("usageSummary", () => {
  it("shows no-usage message for empty history", async () => {
    await usageSummary(undefined, dir);
    expect(stdout).toEqual([]);
    expect(stderr.join("")).toContain("No usage data found.");
  });

  it("marks estimated costs with ~", async () => {
    writeRecord(
      recordWithUsage("r-est", [
        {
          modelId: "universal",
          task: "transcription",
          provider: "assemblyai",
          calls: 1,
          durationMin: 40,
          costUSD: 0.1,
          estimated: true,
        },
      ]),
    );

    await usageSummary(undefined, dir);

    const outText = stdout.join("");
    expect(outText).toContain("universal\tassemblyai\t1\t1\t0\t0\t~$0.10");
    // estimated dollars propagate to the total marker too
    expect(stderr.join("")).toContain("~$0.10");
  });

  it("renders mixed known and unknown costs", async () => {
    // r1: known cost
    writeRecord(
      recordWithUsage("r1", [
        {
          modelId: "gpt-4o",
          task: "summary",
          provider: "assemblyai",
          calls: 2,
          tokensIn: 200,
          tokensOut: 100,
          costUSD: 0.03,
          estimated: false,
        },
      ]),
    );
    // r2: unknown cost (null)
    writeRecord(
      recordWithUsage("r2", [
        {
          modelId: "gpt-4o",
          task: "summary",
          provider: "assemblyai",
          calls: 1,
          tokensIn: 50,
          tokensOut: 25,
          costUSD: null,
          estimated: true,
        },
      ]),
    );

    await usageSummary(undefined, dir);

    // stdout: known cost renders plain — `~` is reserved for ESTIMATED dollars;
    // the unknown entry contributes nothing to the number, and unknown-ness is
    // reported via the stderr "runs have unknown cost" note instead.
    const outText = stdout.join("");
    expect(outText).toContain("gpt-4o\tassemblyai\t2\t3\t250\t125\t$0.03");

    // stderr: header + totals
    const errText = stderr.join("");
    expect(errText).toContain(
      "model\tprovider\truns\tcalls\ttokensIn\ttokensOut\tcostUSD",
    );
    // total includes only known cost ($0.03)
    expect(errText).toContain("total\t\t2\t3\t250\t125\t$0.03");
    // Both runs are in the gpt-4o row which has hasUnknown=true
    expect(errText).toContain("2 runs have unknown cost");
  });

  it("filters by 30d window", async () => {
    writeRecord(
      recordWithUsage("old", [
        {
          modelId: "gpt-4o",
          task: "summary",
          provider: "assemblyai",
          calls: 1,
          tokensIn: 100,
          tokensOut: 50,
          costUSD: 0.01,
          estimated: false,
        },
      ],
      // createdAt 1 year ago — outside any 30d/month window
      { createdAt: "2025-07-15T12:00:00.000Z" }),
    );

    await usageSummary("30d", dir);

    expect(stdout).toEqual([]);
    expect(stderr.join("")).toContain("No usage data for the requested window");
  });
});

// ── usageRuns ────────────────────────────────────────────

describe("usageRuns", () => {
  it("shows no-usage message for empty history", async () => {
    await usageRuns(undefined, dir);
    expect(stdout).toEqual([]);
    expect(stderr.join("")).toContain("No usage data found.");
  });

  it("renders per-run rows with known cost", async () => {
    writeRecord(
      recordWithUsage("abc123", [
        {
          modelId: "gpt-4o",
          task: "summary",
          provider: "assemblyai",
          calls: 1,
          tokensIn: 100,
          tokensOut: 50,
          costUSD: 0.01,
          estimated: false,
        },
      ]),
    );

    await usageRuns(undefined, dir);

    const outText = stdout.join("");
    expect(outText).toContain("abc123");
    expect(outText).toContain("2026-07-15");
    expect(outText).toContain("gpt-4o");
    expect(outText).toContain("$0.01");
  });

  it("renders unknown cost as em-dash and notes it", async () => {
    writeRecord(
      recordWithUsage("legacy-1", [
        {
          modelId: "whisper-1",
          task: "transcription",
          provider: "assemblyai",
          calls: 1,
          costUSD: null,
          estimated: true,
        },
      ]),
    );

    await usageRuns(undefined, dir);

    const outText = stdout.join("");
    expect(outText).toContain("—");

    const errText = stderr.join("");
    expect(errText).toContain("1 runs have unknown cost");
  });

  it("filters by 30d window", async () => {
    writeRecord(
      recordWithUsage("old", [
        {
          modelId: "gpt-4o",
          task: "summary",
          provider: "assemblyai",
          calls: 1,
          tokensIn: 100,
          tokensOut: 50,
          costUSD: 0.01,
          estimated: false,
        },
      ],
      // createdAt 1 year ago — outside any 30d/month window
      { createdAt: "2025-07-15T12:00:00.000Z" }),
    );

    await usageRuns("30d", dir);

    expect(stdout).toEqual([]);
    expect(stderr.join("")).toContain("No usage data for the requested window");
  });
});

// ── usageSummaryJSON ──────────────────────────────────────────

describe("usageSummaryJSON", () => {
  it("returns empty rows for empty history", async () => {
    const json = await usageSummaryJSON(undefined, dir);
    const parsed = JSON.parse(json);
    expect(parsed).toEqual({ window: "all", rows: [] });
  });

  it("includes all ModelSummaryRow fields for populated history", async () => {
    writeRecord(
      recordWithUsage("r1", [
        {
          modelId: "gpt-4o",
          task: "summary",
          provider: "assemblyai",
          calls: 2,
          tokensIn: 200,
          tokensOut: 100,
          costUSD: 0.03,
          estimated: false,
        },
      ]),
    );

    const json = await usageSummaryJSON(undefined, dir);
    const parsed = JSON.parse(json);

    expect(parsed.window).toBe("all");
    expect(parsed.rows).toHaveLength(1);

    const row = parsed.rows[0];
    expect(row).toHaveProperty("modelId", "gpt-4o");
    expect(row).toHaveProperty("provider", "assemblyai");
    expect(row).toHaveProperty("runs", 1);
    expect(row).toHaveProperty("calls", 2);
    expect(row).toHaveProperty("tokensIn", 200);
    expect(row).toHaveProperty("tokensOut", 100);
    expect(row).toHaveProperty("costUSD");
    expect(typeof row.costUSD).toBe("number");
    expect(row).toHaveProperty("hasUnknown", false);
    expect(row).toHaveProperty("hasEstimated", false);
  });

  it("preserves hasUnknown=true for null-cost usage entries", async () => {
    writeRecord(
      recordWithUsage("r-unk", [
        {
          modelId: "whisper-1",
          task: "transcription",
          provider: "assemblyai",
          calls: 1,
          costUSD: null,
          estimated: true,
        },
      ]),
    );

    const json = await usageSummaryJSON(undefined, dir);
    const parsed = JSON.parse(json);

    expect(parsed.rows).toHaveLength(1);
    expect(parsed.rows[0].hasUnknown).toBe(true);
  });

  it("preserves hasEstimated=true for estimated non-null costs", async () => {
    writeRecord(
      recordWithUsage("r-est", [
        {
          modelId: "universal",
          task: "transcription",
          provider: "assemblyai",
          calls: 1,
          costUSD: 0.10,
          estimated: true,
        },
      ]),
    );

    const json = await usageSummaryJSON(undefined, dir);
    const parsed = JSON.parse(json);

    expect(parsed.rows).toHaveLength(1);
    expect(parsed.rows[0].hasEstimated).toBe(true);
  });

  it("writes window as default 'all' when no window argument", async () => {
    const json = await usageSummaryJSON(undefined, dir);
    const parsed = JSON.parse(json);
    expect(parsed.window).toBe("all");
  });

  it("filters by 30d window returning empty rows", async () => {
    writeRecord(
      recordWithUsage("old", [
        {
          modelId: "gpt-4o",
          task: "summary",
          provider: "assemblyai",
          calls: 1,
          tokensIn: 100,
          tokensOut: 50,
          costUSD: 0.01,
          estimated: false,
        },
      ],
      { createdAt: "2025-07-15T12:00:00.000Z" }),
    );

    const json = await usageSummaryJSON("30d", dir);
    const parsed = JSON.parse(json);

    expect(parsed.window).toBe("30d");
    expect(parsed.rows).toHaveLength(0);
  });
});
