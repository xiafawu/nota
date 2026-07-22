/**
 * Catalog cost computation tests:
 * - ×1e-6 unit assertion (e.g. 10k in + 1k out on gpt-5-mini = $0.0045)
 * - Tier pick at non-200k threshold (synthetic 272k fixture)
 * - Null cost for unknown model
 * - Fallback to base rates when no tier matches
 */

import { describe, it, expect } from "vitest";
import { computeSummaryCost, findCatalogEntry } from "../../src/catalog.js";
import type { CatalogCache, CatalogModelEntry } from "../../src/catalog.js";

/** Build a cache from a single-entry models array for easy lookup. */
function cacheWith(...models: CatalogModelEntry[]): CatalogCache {
  return {
    schemaVersion: 1,
    source: "inline",
    etag: "",
    fetchedAt: "2026-07-22T00:00:00Z",
    costUnit: "usd_per_1m_tokens",
    models,
  };
}

function gpt5mini(): CatalogModelEntry {
  return {
    id: "gpt-5-mini",
    provider: "openai",
    label: "GPT-5 mini",
    task: "summary",
    cost: { input: 0.25, output: 2, cacheRead: 0.025, tiers: [] },
    limit: { context: 1000000, output: 16384 },
  };
}

function gemini25Pro(): CatalogModelEntry {
  return {
    id: "gemini-2.5-pro",
    provider: "gemini",
    label: "Gemini 2.5 Pro",
    task: "summary",
    cost: {
      input: 1.25,
      output: 10,
      cacheRead: 0.125,
      tiers: [{ thresholdTokens: 200000, input: 2.5, output: 15, cacheRead: 0.25 }],
    },
    limit: { context: 1048576, output: 65536 },
  };
}

/** Model with a 272000 threshold to test non-200k tier values. */
function gpt5With272k(): CatalogModelEntry {
  return {
    id: "gpt-5-test",
    provider: "openai",
    label: "GPT-5 Test (272k tier)",
    task: "summary",
    cost: {
      input: 1.25,
      output: 10,
      tiers: [{ thresholdTokens: 272000, input: 2.5, output: 15 }],
    },
    limit: { context: 272000, output: 16384 },
  };
}

/** Model with two tiers to test step selection (pick largest ≤ tokensIn). */
function gpt5MultiTier(): CatalogModelEntry {
  return {
    id: "gpt-5-multi",
    provider: "openai",
    label: "GPT-5 Multi-tier",
    task: "summary",
    cost: {
      input: 1,
      output: 4,
      tiers: [
        { thresholdTokens: 128000, input: 2, output: 8 },
        { thresholdTokens: 272000, input: 3, output: 12 },
      ],
    },
    limit: { context: 1000000, output: 16384 },
  };
}

describe("computeSummaryCost — ×1e-6 unit assertion", () => {
  it("gpt-5-mini 10k in + 1k out = $0.0045", () => {
    // (10000/1000000)*0.25 = 0.0025  +  (1000/1000000)*2.0 = 0.002  = 0.0045
    const cost = computeSummaryCost(gpt5mini(), 10_000, 1_000);
    expect(cost).toBeCloseTo(0.0045, 6);
  });

  it("gpt-5-mini 100k in + 50k out = $0.125", () => {
    // (100000/1000000)*0.25 = 0.025  +  (50000/1000000)*2.0 = 0.1  = 0.125
    const cost = computeSummaryCost(gpt5mini(), 100_000, 50_000);
    expect(cost).toBe(0.125);
  });

  it("gpt-5-mini 0 tokens = $0", () => {
    expect(computeSummaryCost(gpt5mini(), 0, 0)).toBe(0);
  });

  it("gemini-2.5-pro base rates below 200k threshold", () => {
    // 100k in + 5k out below 200k threshold
    // (100000/1000000)*1.25 = 0.125  +  (5000/1000000)*10 = 0.05  = 0.175
    const cost = computeSummaryCost(gemini25Pro(), 100_000, 5_000);
    expect(cost).toBeCloseTo(0.175, 6);
  });

  it("unit conversion is exactly ×1e-6, not ×1e-3 or per-token", () => {
    // 1 token * 0.25 per-1M should be 0.00000025, not 0.00025 or 0.25
    const cost = computeSummaryCost(gpt5mini(), 1, 1);
    const expected = (1 / 1_000_000) * 0.25 + (1 / 1_000_000) * 2.0;
    expect(cost).toBe(expected);
  });
});

describe("computeSummaryCost — tier pick at non-200k threshold (272k)", () => {
  it("applies base rates below 272k", () => {
    // 100k < 272k threshold → base rates 1.25/10
    // (100000/1000000)*1.25 + (5000/1000000)*10 = 0.125 + 0.05 = 0.175
    const cost = computeSummaryCost(gpt5With272k(), 100_000, 5_000);
    expect(cost).toBeCloseTo(0.175, 6);
  });

  it("applies tier rates above 272k", () => {
    // 300k > 272k threshold → tier rates 2.5/15
    // (300000/1000000)*2.5 + (10000/1000000)*15 = 0.75 + 0.15 = 0.90
    const cost = computeSummaryCost(gpt5With272k(), 300_000, 10_000);
    expect(cost).toBeCloseTo(0.90, 6);
  });

  it("exactly at threshold (272k) uses tier rates", () => {
    // thresholdTokens ≤ tokensIn → tier applies
    const cost = computeSummaryCost(gpt5With272k(), 272_000, 10_000);
    // (272000/1000000)*2.5 + (10000/1000000)*15 = 0.68 + 0.15 = 0.83
    expect(cost).toBeCloseTo(0.83, 6);
  });
});

describe("computeSummaryCost — multi-tier selection (pick largest ≤ tokensIn)", () => {
  it("uses base rates below smallest tier", () => {
    // 50k < 128k → base rates 1/4
    const cost = computeSummaryCost(gpt5MultiTier(), 50_000, 10_000);
    // (50000/1000000)*1 + (10000/1000000)*4 = 0.05 + 0.04 = 0.09
    expect(cost).toBeCloseTo(0.09, 6);
  });

  it("picks middle tier (128k) when between thresholds", () => {
    // 200k > 128k but < 272k → tier 0 rates 2/8
    const cost = computeSummaryCost(gpt5MultiTier(), 200_000, 20_000);
    // (200000/1000000)*2 + (20000/1000000)*8 = 0.40 + 0.16 = 0.56
    expect(cost).toBeCloseTo(0.56, 6);
  });

  it("picks highest tier (272k) when above all thresholds", () => {
    // 500k > 272k → tier 1 rates 3/12
    const cost = computeSummaryCost(gpt5MultiTier(), 500_000, 50_000);
    // (500000/1000000)*3 + (50000/1000000)*12 = 1.50 + 0.60 = 2.10
    expect(cost).toBeCloseTo(2.10, 6);
  });
});

describe("computeSummaryCost — edge cases", () => {
  it("handles zero input tokens gracefully", () => {
    const cost = computeSummaryCost(gpt5mini(), 0, 1_000);
    // (0) + (1000/1000000)*2 = 0.002
    expect(cost).toBeCloseTo(0.002, 6);
  });

  it("handles zero output tokens gracefully", () => {
    const cost = computeSummaryCost(gpt5mini(), 10_000, 0);
    // (10000/1000000)*0.25 + 0 = 0.0025
    expect(cost).toBeCloseTo(0.0025, 6);
  });

  it("handles large token counts without overflow", () => {
    const cost = computeSummaryCost(gpt5mini(), 10_000_000, 1_000_000);
    // (10000000/1000000)*0.25 + (1000000/1000000)*2.0 = 2.5 + 2.0 = 4.50
    expect(cost).toBeCloseTo(4.50, 6);
  });
});

describe("findCatalogEntry", () => {
  const cache = cacheWith(gpt5mini(), gemini25Pro());

  it("finds existing model by id", () => {
    const entry = findCatalogEntry(cache, "gpt-5-mini");
    expect(entry).toBeDefined();
    expect(entry!.provider).toBe("openai");
  });

  it("returns undefined for unknown model", () => {
    expect(findCatalogEntry(cache, "gpt-6-nonexistent")).toBeUndefined();
  });

  it("is case-sensitive", () => {
    expect(findCatalogEntry(cache, "GPT-5-MINI")).toBeUndefined();
  });
});
