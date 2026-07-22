/**
 * Catalog validation tests — every validation rule from decision §8:
 * - Bounds rejection (0 ≤ input,output ≤ 5000)
 * - cacheRead ≥ 0 and ≤ input
 * - thresholdTokens positive int
 * - Blanking guard (configured model cost drops to 0 while old had non-zero)
 * - Empty models rejection
 * - schemaVersion rejection
 */

import { describe, it, expect } from "vitest";
import { validateCatalog } from "../../src/catalog.js";
import type { CatalogCache, CatalogModelEntry } from "../../src/catalog.js";

/** Minimal valid model entry helper. */
function model(overrides: Partial<CatalogModelEntry> & { id: string }): CatalogModelEntry {
  return {
    id: overrides.id,
    provider: "openai",
    label: `Model ${overrides.id}`,
    task: "summary",
    cost: {
      input: 1,
      output: 5,
      tiers: [],
      ...overrides.cost,
    },
    limit: { context: 1000000, ...overrides.limit },
  };
}

function cache(models: CatalogModelEntry[] = []): CatalogCache {
  return {
    schemaVersion: 1,
    source: "https://models.dev/api.json",
    etag: "\"x\"",
    fetchedAt: "2026-07-22T00:00:00Z",
    costUnit: "usd_per_1m_tokens",
    models,
  };
}

describe("validateCatalog — schemaVersion", () => {
  it("rejects unsupported schemaVersion", () => {
    const c: CatalogCache = { ...cache(), schemaVersion: 2 };
    expect(validateCatalog(c)).toContainEqual(
      expect.stringMatching(/schemaVersion.*2/),
    );
  });

  it("accepts schemaVersion 1", () => {
    expect(validateCatalog(cache([model({ id: "gpt-5" })]))).toEqual([]);
  });
});

describe("validateCatalog — empty models", () => {
  it("rejects empty catalog", () => {
    expect(validateCatalog(cache())).toContainEqual(
      expect.stringMatching(/zero models/),
    );
  });
});

describe("validateCatalog — bounds", () => {
  it("rejects negative input cost", () => {
    const c = cache([model({ id: "m1", cost: { input: -0.1, output: 5, tiers: [] } })]);
    const errs = validateCatalog(c);
    expect(errs.some((e) => e.includes("m1") && e.includes("input") && e.includes("-0.1"))).toBe(true);
  });

  it("rejects input > 5000", () => {
    const c = cache([model({ id: "m1", cost: { input: 5001, output: 5, tiers: [] } })]);
    const errs = validateCatalog(c);
    expect(errs.some((e) => e.includes("out of bounds"))).toBe(true);
  });

  it("rejects output > 5000", () => {
    const c = cache([model({ id: "m1", cost: { input: 1, output: 6000, tiers: [] } })]);
    const errs = validateCatalog(c);
    expect(errs.some((e) => e.includes("out of bounds"))).toBe(true);
  });

  it("accepts boundary cost values (0 and 5000)", () => {
    const c = cache([
      model({ id: "m1", cost: { input: 0, output: 5000, tiers: [] } }),
    ]);
    expect(validateCatalog(c)).toEqual([]);
  });
});

describe("validateCatalog — cacheRead", () => {
  it("rejects negative cacheRead", () => {
    const c = cache([model({ id: "m1", cost: { input: 1, output: 1, cacheRead: -0.1, tiers: [] } })]);
    const errs = validateCatalog(c);
    expect(errs.some((e) => e.includes("cacheRead") && e.includes("≥ 0"))).toBe(true);
  });

  it("rejects cacheRead > input", () => {
    const c = cache([model({ id: "m1", cost: { input: 1, output: 1, cacheRead: 2, tiers: [] } })]);
    const errs = validateCatalog(c);
    expect(errs.some((e) => e.includes("exceeds cost.input"))).toBe(true);
  });

  it("accepts valid cacheRead", () => {
    const c = cache([model({ id: "m1", cost: { input: 10, output: 1, cacheRead: 3, tiers: [] } })]);
    expect(validateCatalog(c)).toEqual([]);
  });

  it("accepts missing cacheRead", () => {
    const c = cache([model({ id: "m1", cost: { input: 1, output: 1, tiers: [] } })]);
    expect(validateCatalog(c)).toEqual([]);
  });
});

describe("validateCatalog — tiers", () => {
  it("rejects non-integer thresholdTokens", () => {
    const c = cache([
      model({
        id: "m1",
        cost: { input: 1, output: 1, tiers: [{ thresholdTokens: 200.5, input: 2, output: 3 }] },
      }),
    ]);
    const errs = validateCatalog(c);
    expect(errs.some((e) => e.includes("thresholdTokens"))).toBe(true);
  });

  it("rejects zero thresholdTokens", () => {
    const c = cache([
      model({
        id: "m1",
        cost: { input: 1, output: 1, tiers: [{ thresholdTokens: 0, input: 2, output: 3 }] },
      }),
    ]);
    const errs = validateCatalog(c);
    expect(errs.some((e) => e.includes("positive integer"))).toBe(true);
  });

  it("rejects negative thresholdTokens", () => {
    const c = cache([
      model({
        id: "m1",
        cost: { input: 1, output: 1, tiers: [{ thresholdTokens: -100, input: 2, output: 3 }] },
      }),
    ]);
    const errs = validateCatalog(c);
    expect(errs.some((e) => e.includes("positive integer"))).toBe(true);
  });


  it("accepts valid tiers", () => {
    const c = cache([
      model({
        id: "m1",
        cost: {
          input: 1, output: 1, tiers: [{ thresholdTokens: 200000, input: 2, output: 3 }],
        },
      }),
    ]);
    expect(validateCatalog(c)).toEqual([]);
  });
});

describe("validateCatalog — blanking guard", () => {
  it("rejects when configured model cost drops to 0 while old was non-zero", () => {
    const prev = cache([model({ id: "gpt-5", cost: { input: 1.25, output: 10, tiers: [] } })]);
    const now = cache([model({ id: "gpt-5", cost: { input: 0, output: 0, tiers: [] } })]);
    const errs = validateCatalog(now, ["gpt-5"], prev);
    expect(errs.some((e) => e.includes("blanking guard"))).toBe(true);
  });

  it("passes when configured model cost is same as before", () => {
    const prev = cache([model({ id: "gpt-5", cost: { input: 1.25, output: 10, tiers: [] } })]);
    // Now same cost, different output value but still non-zero
    const now = cache([model({ id: "gpt-5", cost: { input: 1.25, output: 8, tiers: [] } })]);
    const errs = validateCatalog(now, ["gpt-5"], prev);
    expect(errs.filter((e) => e.includes("blanking guard"))).toEqual([]);
  });

  it("passes when configured model is not in prev cache (new model)", () => {
    const prev = cache([]);
    const now = cache([model({ id: "gpt-5", cost: { input: 0, output: 0, tiers: [] } })]);
    const errs = validateCatalog(now, ["gpt-5"], prev);
    expect(errs.filter((e) => e.includes("blanking guard"))).toEqual([]);
  });

  it("passes when configured model not in new cache (zombie — handled elsewhere)", () => {
    const prev = cache([model({ id: "gpt-5", cost: { input: 1.25, output: 10, tiers: [] } })]);
    const now = cache([]);
    const errs = validateCatalog(now, ["gpt-5"], prev);
    expect(errs.filter((e) => e.includes("blanking guard"))).toEqual([]);
  });
});

describe("validateCatalog — id checks", () => {
  it("rejects model entry missing string id", () => {
    const c = cache([{ ...model({ id: "" }), id: "" as never }]);
    const errs = validateCatalog(c);
    expect(errs.some((e) => e.includes("missing string id"))).toBe(true);
  });
});

describe("validateCatalog — multiple errors", () => {
  it("reports all errors, not just the first", () => {
    const c = cache([
      model({ id: "bad1", cost: { input: -1, output: 9999, tiers: [] } }),
      model({ id: "bad2", cost: { input: 1, output: 1, tiers: [{ thresholdTokens: 0, input: 2, output: 3 }] } }),
    ]);
    const errs = validateCatalog(c);
    expect(errs.length).toBeGreaterThanOrEqual(2);
  });
});
