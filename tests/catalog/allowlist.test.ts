/**
 * Allowlist predicate tests — verify that the structural + per-provider rules
 * admit exactly the expected set and exclude documented near-misses.
 *
 * Uses inline fixture data (no network).
 */

import { describe, it, expect } from "vitest";

// Reuse the module-under-test types and predicates by importing
import { filterCatalog, validateRawCatalog } from "../../src/catalog.js";

// ── Fixture: a synthetic api.json slice ──────────────────────────────────────
// Covers every admitted model plus every near-miss from the handoff spec.
// This is the smallest set that exercises every predicate branch.

const FIXTURE = {
  openai: {
    models: {
      // ADMITTED — gpt-5 mainline
      "gpt-5": {
        id: "gpt-5",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 1.25, output: 10 },
        limit: { context: 1000000, output: 16384 },
      },
      "gpt-5-mini": {
        id: "gpt-5-mini",
        name: "GPT-5 mini",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.25, output: 2 },
        limit: { context: 1000000, output: 16384 },
      },
      "gpt-5.1": {
        id: "gpt-5.1",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 2, output: 8 },
        limit: { context: 1000000, output: 16384 },
      },
      "gpt-5.2": {
        id: "gpt-5.2",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 2.5, output: 10 },
        limit: { context: 1000000, output: 16384 },
      },
      "gpt-5.4": {
        id: "gpt-5.4",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 1.25, output: 10 },
        limit: { context: 1000000, output: 16384 },
      },
      "gpt-5.4-mini": {
        id: "gpt-5.4-mini",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.25, output: 2 },
        limit: { context: 1000000, output: 16384 },
      },
      "gpt-5.5": {
        id: "gpt-5.5",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 1, output: 8 },
        limit: { context: 1000000, output: 16384 },
      },
      "gpt-5.6": {
        id: "gpt-5.6",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 2.5, output: 10 },
        limit: { context: 1000000, output: 16384 },
      },
      // EXCLUDED — previous generation still listed on models.dev. A bare
      // `gpt-\d+` pattern matches these; the predicate must floor at gen 5.
      "gpt-4": {
        id: "gpt-4",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 30, output: 60 },
        limit: { context: 8192, output: 8192 },
      },
      "gpt-4.1": {
        id: "gpt-4.1",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 2, output: 8 },
        limit: { context: 1047576, output: 32768 },
      },
      "gpt-4.1-mini": {
        id: "gpt-4.1-mini",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.4, output: 1.6 },
        limit: { context: 1047576, output: 32768 },
      },
      // EXCLUDED — near-misses
      "gpt-5.4-pro": {
        id: "gpt-5.4-pro",
        family: "gpt-codex",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 3, output: 15 },
        limit: { context: 272000, output: 16384 },
      },
      "gpt-5.3-chat-latest": {
        id: "gpt-5.3-chat-latest",
        family: "gpt-chat",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 1.5, output: 8 },
        limit: { context: 1000000, output: 16384 },
      },
      "gpt-5.1-codex": {
        id: "gpt-5.1-codex",
        family: "gpt-codex",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 2, output: 8 },
        limit: { context: 1000000, output: 16384 },
      },
      "gpt-5.6-sol": {
        id: "gpt-5.6-sol",
        family: "gpt-sol",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 3, output: 15 },
        limit: { context: 1000000, output: 16384 },
      },
      // Also exclude: non-text output (image gen)
      "gpt-5-image": {
        id: "gpt-5-image",
        family: "gpt-chat",
        modalities: { input: ["text", "image"], output: ["text", "image"] },
        tool_call: true,
        cost: { input: 2.5, output: 10 },
        limit: { context: 1000000, output: 16384 },
      },
      // Exclude: audio input
      "gpt-5-audio": {
        id: "gpt-5-audio",
        family: "gpt-chat",
        modalities: { input: ["text", "audio"], output: ["text"] },
        tool_call: true,
        cost: { input: 2.5, output: 10 },
        limit: { context: 1000000, output: 16384 },
      },
    },
  },
  google: {
    models: {
      // ADMITTED
      "gemini-2.5-flash": {
        id: "gemini-2.5-flash",
        family: "gemini-flash",
        // Real shape: Gemini chat models are multimodal on input (incl. audio).
        // The predicate must not reject them for that — regression trap for
        // the audio-input gate that once wiped all of Gemini.
        modalities: { input: ["text", "image", "audio", "video", "pdf"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.3, output: 2.5 },
        limit: { context: 1048576, output: 65536 },
      },
      "gemini-2.5-pro": {
        id: "gemini-2.5-pro",
        family: "gemini-pro",
        modalities: { input: ["text", "image", "audio", "video", "pdf"], output: ["text"] },
        tool_call: true,
        cost: { input: 1.25, output: 10 },
        limit: { context: 1048576, output: 65536 },
      },
      "gemini-3.5-flash": {
        id: "gemini-3.5-flash",
        family: "gemini-flash",
        // Real shape: Gemini chat models are multimodal on input (incl. audio).
        // The predicate must not reject them for that — regression trap for
        // the audio-input gate that once wiped all of Gemini.
        modalities: { input: ["text", "image", "audio", "video", "pdf"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.15, output: 0.6 },
        limit: { context: 1048576, output: 65536 },
      },
      "gemini-3.6-flash": {
        id: "gemini-3.6-flash",
        family: "gemini-flash",
        // Real shape: Gemini chat models are multimodal on input (incl. audio).
        // The predicate must not reject them for that — regression trap for
        // the audio-input gate that once wiped all of Gemini.
        modalities: { input: ["text", "image", "audio", "video", "pdf"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.1, output: 0.4 },
        limit: { context: 1048576, output: 65536 },
      },
      // EXCLUDED — near-misses
      "gemini-3-pro-preview": {
        id: "gemini-3-pro-preview",
        family: "gemini-pro",
        modalities: { input: ["text", "image", "audio", "video", "pdf"], output: ["text"] },
        tool_call: true,
        cost: { input: 2, output: 12 },
        limit: { context: 1048576, output: 65536 },
      },
      "gemini-3.1-flash-lite": {
        id: "gemini-3.1-flash-lite",
        family: "gemini-flash-lite",
        modalities: { input: ["text", "image"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.075, output: 0.3 },
        limit: { context: 1048576, output: 65536 },
      },
      "gemini-flash-latest": {
        id: "gemini-flash-latest",
        family: "gemini-flash",
        // Real shape: Gemini chat models are multimodal on input (incl. audio).
        // The predicate must not reject them for that — regression trap for
        // the audio-input gate that once wiped all of Gemini.
        modalities: { input: ["text", "image", "audio", "video", "pdf"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.3, output: 2.5 },
        limit: { context: 1048576, output: 65536 },
      },
      "gemini-2.5-flash-image": {
        id: "gemini-2.5-flash-image",
        family: "gemini-flash",
        modalities: { input: ["text", "image"], output: ["text", "image"] },
        tool_call: true,
        cost: { input: 0.3, output: 2.5 },
        limit: { context: 1048576, output: 65536 },
      },
      // Exclude: deprecated
      "gemini-2.0-flash": {
        id: "gemini-2.0-flash",
        family: "gemini-flash",
        status: "deprecated",
        modalities: { input: ["text", "image"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.15, output: 0.6 },
        limit: { context: 1048576, output: 65536 },
      },
    },
  },
  deepseek: {
    models: {
      // ADMITTED
      "deepseek-v4-flash": {
        id: "deepseek-v4-flash",
        family: "deepseek",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.14, output: 0.28 },
        limit: { context: 1000000, output: 384000 },
      },
      "deepseek-v4-pro": {
        id: "deepseek-v4-pro",
        family: "deepseek",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.435, output: 0.87 },
        limit: { context: 1000000, output: 384000 },
      },
      // EXCLUDED — near-misses
      "deepseek-chat": {
        id: "deepseek-chat",
        family: "deepseek",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.5, output: 1.5 },
        limit: { context: 1000000, output: 384000 },
      },
      "deepseek-reasoner": {
        id: "deepseek-reasoner",
        family: "deepseek-thinking",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 1, output: 4 },
        limit: { context: 1000000, output: 384000 },
      },
      // v3 — too old
      "deepseek-v3-flash": {
        id: "deepseek-v3-flash",
        family: "deepseek",
        modalities: { input: ["text"], output: ["text"] },
        tool_call: true,
        cost: { input: 0.1, output: 0.2 },
        limit: { context: 1000000, output: 384000 },
      },
    },
  },
};

const EXPECTED_ADMITTED = [
  "deepseek-v4-flash",
  "deepseek-v4-pro",
  "gemini-2.5-flash",
  "gemini-2.5-pro",
  "gemini-3.5-flash",
  "gemini-3.6-flash",
  "gpt-5",
  "gpt-5-mini",
  "gpt-5.1",
  "gpt-5.2",
  "gpt-5.4",
  "gpt-5.4-mini",
  "gpt-5.5",
  "gpt-5.6",
];

const NEAR_MISSES = [
  "gpt-4",
  "gpt-4.1",
  "gpt-4.1-mini",
  "gpt-5.4-pro",
  "gpt-5.3-chat-latest",
  "gpt-5.1-codex",
  "gpt-5.6-sol",
  "gpt-5-image",
  "gpt-5-audio",
  "gemini-3-pro-preview",
  "gemini-3.1-flash-lite",
  "gemini-flash-latest",
  "gemini-2.5-flash-image",
  "gemini-2.0-flash",
  "deepseek-chat",
  "deepseek-reasoner",
  "deepseek-v3-flash",
];

describe("allowlist — admit exactly the 14 handoff-specified models", () => {
  const result = filterCatalog(FIXTURE as never);
  const admittedIds = result.map((m) => m.id).sort();

  it("admits all 14 expected models", () => {
    expect(admittedIds).toEqual([...EXPECTED_ADMITTED].sort());
  });

  it("does not admit any near-miss ids", () => {
    for (const near of NEAR_MISSES) {
      expect(admittedIds).not.toContain(near);
    }
  });

  it("maps google provider to gemini", () => {
    for (const m of result) {
      if (m.id.startsWith("gemini")) {
        expect(m.provider).toBe("gemini");
      }
    }
  });

  it("maps openai provider to openai", () => {
    for (const m of result) {
      if (m.id.startsWith("gpt")) {
        expect(m.provider).toBe("openai");
      }
    }
  });

  it("maps the models.dev name field to label, falling back to id", () => {
    const mini = result.find((m) => m.id === "gpt-5-mini");
    expect(mini?.label).toBe("GPT-5 mini");
    // Entries without a name keep the id as label
    const flash = result.find((m) => m.id === "deepseek-v4-flash");
    expect(flash?.label).toBe("deepseek-v4-flash");
  });

  it("maps deepseek provider to deepseek", () => {
    for (const m of result) {
      if (m.id.startsWith("deepseek")) {
        expect(m.provider).toBe("deepseek");
      }
    }
  });

  it("flattens tier data from raw format", () => {
    const raw = {
      openai: { models: {} },
      google: {
        models: {
          "gemini-2.5-pro": {
            id: "gemini-2.5-pro",
            family: "gemini-pro",
            modalities: { input: ["text", "image"], output: ["text"] },
            tool_call: true,
            cost: {
              input: 1.25,
              output: 10,
              tiers: [
                {
                  input: 2.5,
                  output: 15,
                  tier: { type: "context", size: 200000 },
                },
              ],
            },
            limit: { context: 1048576, output: 65536 },
          },
        },
      },
      deepseek: { models: {} },
    };
    const entries = filterCatalog(raw as never);
    expect(entries).toHaveLength(1);
    expect(entries[0].cost.tiers).toHaveLength(1);
    expect(entries[0].cost.tiers[0].thresholdTokens).toBe(200000);
  });

  it("drops non-context tiers", () => {
    const raw = {
      openai: { models: {} },
      google: {
        models: {
          "gemini-2.5-pro": {
            id: "gemini-2.5-pro",
            family: "gemini-pro",
            modalities: { input: ["text", "image"], output: ["text"] },
            tool_call: true,
            cost: {
              input: 1.25,
              output: 10,
              tiers: [
                {
                  input: 2.5,
                  output: 15,
                  tier: { type: "context", size: 200000 },
                },
                {
                  input: 1,
                  output: 1,
                  tier: { type: "prompt_batch", size: 50000 },
                },
              ],
            },
            limit: { context: 1048576, output: 65536 },
          },
        },
      },
      deepseek: { models: {} },
    };
    const entries = filterCatalog(raw as never);
    expect(entries).toHaveLength(1);
    expect(entries[0].cost.tiers).toHaveLength(1);
    expect(entries[0].cost.tiers[0].thresholdTokens).toBe(200000);
  });
});

describe("validateRawCatalog", () => {
  it("passes for valid fixture", () => {
    const errors = validateRawCatalog(FIXTURE as never);
    expect(errors).toEqual([]);
  });

  it("rejects null/undefined", () => {
    expect(validateRawCatalog(null)).not.toEqual([]);
    expect(validateRawCatalog(undefined)).not.toEqual([]);
  });

  it("rejects missing providers", () => {
    const errors = validateRawCatalog({});
    expect(errors.length).toBeGreaterThanOrEqual(3);
    expect(errors.some((e) => e.includes("openai"))).toBe(true);
    expect(errors.some((e) => e.includes("google"))).toBe(true);
    expect(errors.some((e) => e.includes("deepseek"))).toBe(true);
  });

  it("rejects empty models within a provider", () => {
    const raw = {
      openai: { models: {} },
      google: { models: { "gemini-2.5-flash": { id: "gemini-2.5-flash", cost: { input: 0.3, output: 2.5 } } } },
      deepseek: { models: { "deepseek-v4-flash": { id: "deepseek-v4-flash", cost: { input: 0.14, output: 0.28 } } } },
    };
    const errors = validateRawCatalog(raw);
    expect(errors.some((e) => e.includes("openai") && e.includes("empty"))).toBe(true);
  });
});
