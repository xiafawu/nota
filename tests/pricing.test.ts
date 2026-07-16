import { describe, it, expect } from "vitest";
import { costForUsage, PRICING } from "../src/pricing.js";
import type { UsageEntry } from "../src/pipeline/history.js";

function entry(overrides: Partial<UsageEntry> = {}): UsageEntry {
  return {
    modelId: "gpt-5-mini",
    task: "summary",
    provider: "whisper",
    calls: 1,
    tokensIn: 100_000,
    tokensOut: 10_000,
    costUSD: null,
    estimated: false,
    ...overrides,
  };
}

describe("PRICING", () => {
  it("has a pricedAsOf date", () => {
    expect(PRICING.pricedAsOf).toBe("2026-07-14");
  });

  it("includes all summary models", () => {
    const summaryModels = ["gpt-5-mini", "gpt-5", "gpt-4o", "gpt-4.1", "gemini-2.5-flash", "gemini-2.5-pro"];
    for (const id of summaryModels) {
      expect(PRICING.models[id]).toBeDefined();
      expect(PRICING.models[id]).toHaveProperty("inputPer1M");
    }
  });

  it("includes all transcription models", () => {
    const transcribeModels = ["universal", "whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"];
    for (const id of transcribeModels) {
      expect(PRICING.models[id]).toBeDefined();
      expect(PRICING.models[id]).toHaveProperty("ratePerMin");
    }
  });
});

describe("costForUsage — summary models", () => {
  it("computes gpt-5-mini cost", () => {
    const e = entry({ modelId: "gpt-5-mini", tokensIn: 1_000_000, tokensOut: 1_000_000 });
    expect(costForUsage(e)).toBeCloseTo(2.25, 5); // 0.25 + 2.00
  });

  it("computes gpt-5 cost", () => {
    const e = entry({ modelId: "gpt-5", tokensIn: 1_000_000, tokensOut: 1_000_000 });
    expect(costForUsage(e)).toBeCloseTo(11.25, 5); // 1.25 + 10.00
  });

  it("computes gpt-4o cost", () => {
    const e = entry({ modelId: "gpt-4o", tokensIn: 1_000_000, tokensOut: 1_000_000 });
    expect(costForUsage(e)).toBeCloseTo(12.50, 5); // 2.50 + 10.00
  });

  it("computes gpt-4.1 cost", () => {
    const e = entry({ modelId: "gpt-4.1", tokensIn: 1_000_000, tokensOut: 1_000_000 });
    expect(costForUsage(e)).toBeCloseTo(10.00, 5); // 2.00 + 8.00
  });

  it("computes gemini-2.5-flash cost", () => {
    const e = entry({ modelId: "gemini-2.5-flash", tokensIn: 1_000_000, tokensOut: 1_000_000 });
    expect(costForUsage(e)).toBeCloseTo(2.80, 5); // 0.30 + 2.50
  });

  describe("gemini-2.5-pro tiered pricing", () => {
    it("uses lower tier when ≤200k tokens in", () => {
      const e = entry({ modelId: "gemini-2.5-pro", tokensIn: 200_000, tokensOut: 100_000 });
      // 200k * 1.25/1M + 100k * 10.00/1M = 0.25 + 1.00 = 1.25
      expect(costForUsage(e)).toBeCloseTo(1.25, 5);
    });

    it("uses higher tier when >200k tokens in", () => {
      const e = entry({ modelId: "gemini-2.5-pro", tokensIn: 200_001, tokensOut: 100_000 });
      // 200001 * 2.50/1M + 100k * 15.00/1M ≈ 0.5000025 + 1.50 = 2.0000025
      expect(costForUsage(e)).toBeCloseTo(2.0000025, 5);
    });

    it("exactly at threshold uses lower tier", () => {
      const e = entry({ modelId: "gemini-2.5-pro", tokensIn: 200_000, tokensOut: 0 });
      expect(costForUsage(e)).toBeCloseTo(0.25, 5); // 200k * 1.25/1M
    });
  });

  it("returns null for unknown model id", () => {
    const e = entry({ modelId: "unknown-model" });
    expect(costForUsage(e)).toBeNull();
  });

  it("returns null when tokensIn is missing", () => {
    const e = entry({ tokensIn: undefined });
    expect(costForUsage(e)).toBeNull();
  });

  it("returns null when tokensOut is missing", () => {
    const e = entry({ tokensOut: undefined });
    expect(costForUsage(e)).toBeNull();
  });
});

describe("costForUsage — transcription models", () => {
  it("computes AssemblyAI universal cost", () => {
    // $0.15/hr = $0.0025/min
    const e = entry({ modelId: "universal", task: "transcription", durationMin: 60, tokensIn: undefined, tokensOut: undefined });
    expect(costForUsage(e)).toBeCloseTo(0.15, 5);
  });

  it("computes whisper-1 cost", () => {
    const e = entry({ modelId: "whisper-1", task: "transcription", durationMin: 10, tokensIn: undefined, tokensOut: undefined });
    expect(costForUsage(e)).toBeCloseTo(0.06, 5); // 10 * 0.006
  });

  it("computes gpt-4o-transcribe cost", () => {
    const e = entry({ modelId: "gpt-4o-transcribe", task: "transcription", durationMin: 5, tokensIn: undefined, tokensOut: undefined });
    expect(costForUsage(e)).toBeCloseTo(0.03, 5); // 5 * 0.006
  });

  it("computes gpt-4o-mini-transcribe cost", () => {
    const e = entry({ modelId: "gpt-4o-mini-transcribe", task: "transcription", durationMin: 30, tokensIn: undefined, tokensOut: undefined });
    expect(costForUsage(e)).toBeCloseTo(0.09, 5); // 30 * 0.003
  });

  it("returns null when durationMin is missing", () => {
    const e = entry({ modelId: "whisper-1", task: "transcription", tokensIn: undefined, tokensOut: undefined, durationMin: undefined });
    expect(costForUsage(e)).toBeNull();
  });
});

describe("costForUsage — shape guards", () => {
  it("returns null when summary entry has transcription-only rate", () => {
    const e = entry({
      modelId: "whisper-1",
      task: "summary",
      tokensIn: 1000,
      tokensOut: 500,
      durationMin: undefined,
    });
    // whisper-1 is a TranscriptionRate, task is "summary" → shape mismatch → null
    expect(costForUsage(e)).toBeNull();
  });

  it("returns null when transcription entry has summary-only rate", () => {
    const e = entry({
      modelId: "gpt-5-mini",
      task: "transcription",
      tokensIn: undefined,
      tokensOut: undefined,
      durationMin: 10,
    });
    // gpt-5-mini is a SummaryRate, task is "transcription" → shape mismatch → null
    expect(costForUsage(e)).toBeNull();
  });
});
