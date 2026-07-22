/**
 * Pricing tests:
 * - Transcription rates are static in PRICING
 * - Summary cost comes from the catalog (cost.test.ts covers full unit assertion)
 * - costForUsage routes correctly for both tasks
 */

import { describe, it, expect } from "vitest";
import { costForUsage, makeSummaryUsage, PRICING } from "../src/pricing.js";
import type { UsageEntry } from "../src/pipeline/history.js";

function entry(overrides: Partial<UsageEntry> = {}): UsageEntry {
  return {
    modelId: "gpt-5-mini",
    task: "summary",
    provider: "openai",
    calls: 1,
    tokensIn: 1000,
    tokensOut: 500,
    costUSD: null,
    estimated: false,
    ...overrides,
  };
}

describe("PRICING — transcription-only", () => {
  it("has a pricedAsOf date", () => {
    expect(PRICING.pricedAsOf).toBe("2026-07-14");
  });

  it("includes only transcription models", () => {
    const keys = Object.keys(PRICING.models);
    expect(keys).toEqual([
      "universal",
      "whisper-1",
      "gpt-4o-transcribe",
      "gpt-4o-mini-transcribe",
    ]);
    for (const id of keys) {
      expect(PRICING.models[id]).toHaveProperty("ratePerMin");
    }
  });
});

describe("costForUsage — transcription models", () => {
  it("computes AssemblyAI universal cost ($0.15/hr = $0.0025/min, 10 min)", () => {
    const cost = costForUsage(
      entry({ modelId: "universal", task: "transcription", provider: "assemblyai", durationMin: 10 }),
    );
    expect(cost).toBeCloseTo(0.025, 6);
  });

  it("computes whisper-1 cost ($0.006/min, 5 min)", () => {
    const cost = costForUsage(
      entry({ modelId: "whisper-1", task: "transcription", provider: "openai", durationMin: 5 }),
    );
    expect(cost).toBe(0.03);
  });

  it("computes gpt-4o-transcribe cost", () => {
    const cost = costForUsage(
      entry({ modelId: "gpt-4o-transcribe", task: "transcription", provider: "openai", durationMin: 10 }),
    );
    expect(cost).toBe(0.06);
  });

  it("computes gpt-4o-mini-transcribe cost", () => {
    const cost = costForUsage(
      entry({ modelId: "gpt-4o-mini-transcribe", task: "transcription", provider: "openai", durationMin: 10 }),
    );
    expect(cost).toBe(0.03);
  });

  it("returns null when durationMin is missing", () => {
    const cost = costForUsage(
      entry({ modelId: "whisper-1", task: "transcription", provider: "openai", durationMin: undefined }),
    );
    expect(cost).toBeNull();
  });

  it("returns null for unknown transcription model", () => {
    const cost = costForUsage(
      entry({ modelId: "nonexistent", task: "transcription", provider: "openai", durationMin: 10 }),
    );
    expect(cost).toBeNull();
  });
});

describe("costForUsage — summary models (catalog-backed)", () => {
  it("computes gpt-5-mini cost from baked catalog", () => {
    const cost = costForUsage(
      entry({ modelId: "gpt-5-mini", task: "summary", tokensIn: 10_000, tokensOut: 1_000 }),
    );
    expect(cost).toBeCloseTo(0.0045, 6);
  });

  it("computes gemini-2.5-pro cost with tier from baked catalog", () => {
    const cost = costForUsage(
      entry({ modelId: "gemini-2.5-pro", task: "summary", tokensIn: 300_000, tokensOut: 10_000 }),
    );
    expect(cost).toBeCloseTo(0.90, 6);
  });

  it("returns null when tokensIn is missing", () => {
    const cost = costForUsage(
      entry({ modelId: "gpt-5-mini", task: "summary", tokensIn: undefined, tokensOut: 500 }),
    );
    expect(cost).toBeNull();
  });

  it("returns null when tokensOut is missing", () => {
    const cost = costForUsage(
      entry({ modelId: "gpt-5-mini", task: "summary", tokensIn: 1000, tokensOut: undefined }),
    );
    expect(cost).toBeNull();
  });

  it("returns null for unknown summary model", () => {
    const cost = costForUsage(
      entry({ modelId: "nonexistent", task: "summary" }),
    );
    expect(cost).toBeNull();
  });
});

describe("costForUsage — shape guards", () => {
  it("returns null when summary entry uses a transcription-only model", () => {
    const cost = costForUsage(
      entry({ modelId: "universal", task: "summary", tokensIn: 1000, tokensOut: 500 }),
    );
    expect(cost).toBeNull();
  });

  it("returns null when transcription entry uses a summary-only model", () => {
    const cost = costForUsage(
      entry({ modelId: "gpt-5-mini", task: "transcription", durationMin: 10 }),
    );
    expect(cost).toBeNull();
  });
});

describe("makeSummaryUsage", () => {
  it("includes pricedAsOf from catalog", () => {
    const usage = makeSummaryUsage("gpt-5-mini", "assemblyai", {
      calls: 1,
      tokensIn: 1000,
      tokensOut: 500,
    });
    expect(usage.pricedAsOf).toBeDefined();
    expect(typeof usage.pricedAsOf).toBe("string");
    expect(usage.costUSD).toBeCloseTo(0.00125, 6);
  });
});
