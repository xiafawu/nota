import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  computeSummaryCost,
  costNoteFor,
  effectiveCatalog,
  mergeCurated,
  refreshCatalog,
  sanitizeCatalog,
  type CatalogCache,
  type CatalogModelEntry,
} from "../src/catalog.js";
import {
  OPENROUTER_BASE_URL,
  OPENROUTER_COST_NOTE,
  OPENROUTER_MODELS,
} from "../src/openrouter.js";
import {
  DEEPSEEK_BASE_URL,
  GEMINI_OPENAI_BASE_URL,
  getModel,
  httpModelsForTask,
  modelsForTask,
  providerForBaseURL,
  requireModel,
  usesMaxTokensParam,
} from "../src/registry.js";
import { summaryTokenLimit } from "../src/pipeline/summarize.js";
import { settingsSet, settingsGet } from "../src/cli/settings.js";
import { printConfig } from "../src/cli/config.js";

const SONNET = "openrouter/anthropic/claude-sonnet-5";

// ── Shortlist shape ──────────────────────────────────────────────────────────

describe("the OpenRouter shortlist", () => {
  it("is six namespaced, unpriced, http, curated summary entries", () => {
    expect(OPENROUTER_MODELS).toHaveLength(6);
    for (const m of OPENROUTER_MODELS) {
      expect(m.id.startsWith("openrouter/")).toBe(true);
      expect(m.provider).toBe("openrouter");
      expect(m.task).toBe("summary");
      expect(m.execution).toBe("http");
      expect(m.origin).toBe("curated");
      // No pricing is stored — a figure here would be a guess about a route
      // OpenRouter picks for us.
      expect(m.cost).toBeUndefined();
      expect(m.costNote).toBe(OPENROUTER_COST_NOTE);
    }
  });

  it("carries the exact slugs verified against the live model list", () => {
    expect(OPENROUTER_MODELS.map((m) => m.id)).toEqual([
      "openrouter/anthropic/claude-sonnet-5",
      "openrouter/anthropic/claude-haiku-4.5",
      "openrouter/moonshotai/kimi-k2.6",
      "openrouter/qwen/qwen3.7-max",
      "openrouter/z-ai/glm-5.2",
      "openrouter/meta-llama/llama-4-maverick",
    ]);
  });
});

// ── Registry resolution ──────────────────────────────────────────────────────

describe("registry resolution of a namespaced id", () => {
  it("derives provider, key, and base URL from the namespace", () => {
    const entry = requireModel(SONNET, "summary");
    expect(entry.provider).toBe("openrouter");
    expect(entry.apiKeyEnv).toBe("OPENROUTER_API_KEY");
    expect(entry.baseURL).toBe(OPENROUTER_BASE_URL);
    expect(entry.execution).toBe("http");
  });

  it("asks OpenRouter for its own slug, not for Nota's namespaced id", () => {
    expect(requireModel(SONNET, "summary").wireId).toBe("anthropic/claude-sonnet-5");
    // Flat ids are unchanged: wireId is the id.
    expect(requireModel("gpt-5-mini", "summary").wireId).toBe("gpt-5-mini");
  });

  it("rejects an id in a namespace Nota has no provider for", () => {
    expect(getModel("bedrock/anthropic/claude-sonnet-5")).toBeUndefined();
    expect(() => requireModel("bedrock/anthropic/claude-sonnet-5", "summary")).toThrow(
      /Unknown summary model/,
    );
  });

  it("lists the shortlist among the summary models", () => {
    const ids = modelsForTask("summary").map((m) => m.id);
    for (const m of OPENROUTER_MODELS) expect(ids).toContain(m.id);
  });
});

// ── Structural filtering (the mechanism ADR 0002 mandates) ───────────────────

function cacheWith(models: CatalogModelEntry[]): CatalogCache {
  return {
    schemaVersion: 1,
    source: "test",
    etag: '"t"',
    fetchedAt: "2026-07-22T00:00:00Z",
    costUnit: "usd_per_1m_tokens",
    models,
  };
}

function entry(over: Partial<CatalogModelEntry>): CatalogModelEntry {
  return {
    id: "gpt-5-mini",
    provider: "openai",
    label: "GPT-5 mini",
    task: "summary",
    cost: { input: 0.25, output: 2, tiers: [] },
    limit: { context: 1_000_000 },
    ...over,
  };
}

describe("sanitizeCatalog", () => {
  it("drops an entry whose namespace names no provider, per entry", () => {
    const sane = sanitizeCatalog(
      cacheWith([
        entry({}),
        entry({ id: "bedrock/anthropic/claude", provider: "openai" }),
      ]),
    );
    expect(sane.models.map((m) => m.id)).toEqual(["gpt-5-mini"]);
  });

  it("drops an entry whose execution kind this build does not know", () => {
    const sane = sanitizeCatalog(
      cacheWith([
        entry({}),
        entry({ id: "gpt-5", execution: "wasm" as never }),
      ]),
    );
    expect(sane.models.map((m) => m.id)).toEqual(["gpt-5-mini"]);
  });

  it("keeps a cli entry — it is known, just not runnable over HTTP", () => {
    // The point is that the kind is recognized, so the entry survives
    // sanitizing and is excluded later by the surfaces that filter on execution
    // rather than by being dropped here (ADR 0003 gives `cli` its members).
    const sane = sanitizeCatalog(cacheWith([entry({ execution: "cli" })]));
    expect(sane.models).toHaveLength(1);
    expect(sane.models[0].execution).toBe("cli");
  });
});

describe("httpModelsForTask", () => {
  it("filters on the execution kind, not on the id", () => {
    const ids = httpModelsForTask("summary").map((m) => m.id);
    // The OpenRouter entries are http, so a structural filter keeps them —
    // an id-prefix filter of the kind ADR 0002 forbids would not.
    expect(ids).toContain(SONNET);
    expect(httpModelsForTask("summary").every((m) => m.execution === "http")).toBe(true);
  });
});

// ── Curated merge survives a refresh ─────────────────────────────────────────

describe("a catalog refresh cannot remove the shortlist", () => {
  const originalCatalogPath = process.env.NOTA_CATALOG_PATH;
  let cachePath: string;

  beforeEach(() => {
    cachePath = path.join(
      mkdtempSync(path.join(tmpdir(), "nota-openrouter-catalog-")),
      "models-catalog.json",
    );
    process.env.NOTA_CATALOG_PATH = cachePath;
  });

  afterEach(() => {
    process.env.NOTA_CATALOG_PATH = originalCatalogPath;
    vi.unstubAllGlobals();
  });

  const upstream = {
    openai: {
      models: {
        "gpt-5-mini": {
          id: "gpt-5-mini",
          name: "GPT-5 mini",
          tool_call: true,
          modalities: { input: ["text"], output: ["text"] },
          cost: { input: 0.25, output: 2 },
          limit: { context: 1_000_000 },
        },
      },
    },
    google: {
      models: {
        "gemini-3.6-flash": {
          id: "gemini-3.6-flash",
          name: "Gemini 3.6 Flash",
          family: "gemini-flash",
          modalities: { input: ["text", "audio"], output: ["text"] },
          cost: { input: 0.1, output: 0.4 },
          limit: { context: 1_048_576 },
        },
      },
    },
    deepseek: {
      models: {
        "deepseek-v4-flash": {
          id: "deepseek-v4-flash",
          name: "DeepSeek V4 Flash",
          tool_call: true,
          modalities: { input: ["text"], output: ["text"] },
          cost: { input: 0.14, output: 0.28 },
          limit: { context: 1_000_000 },
        },
      },
    },
  };

  it("writes only auto-admitted ids, and still serves the shortlist", async () => {
    vi.stubGlobal("fetch", async () =>
      new Response(JSON.stringify(upstream), {
        status: 200,
        headers: { "content-type": "application/json", etag: '"fresh"' },
      }),
    );

    const result = await refreshCatalog();
    expect(result.ok).toBe(true);

    // The cache on disk is the auto-admitted half only: the curated entries
    // live in code, which is exactly why a refresh has nothing to remove.
    const written = JSON.parse(readFileSync(cachePath, "utf-8")) as CatalogCache;
    expect(written.models.map((m) => m.id).sort()).toEqual([
      "deepseek-v4-flash",
      "gemini-3.6-flash",
      "gpt-5-mini",
    ]);
    for (const m of OPENROUTER_MODELS) {
      expect(result.removed).not.toContain(m.id);
      expect(result.added).not.toContain(m.id);
    }

    const { catalog } = effectiveCatalog();
    for (const m of OPENROUTER_MODELS) {
      expect(catalog.models.map((x) => x.id)).toContain(m.id);
    }
    // And the refreshed auto entries are there too.
    expect(catalog.models.map((m) => m.id)).toContain("gpt-5-mini");
  });
});

describe("mergeCurated", () => {
  it("lets a real cache entry win over the hand-written stub", () => {
    const upstreamSonnet = entry({
      id: SONNET,
      provider: "openrouter",
      label: "from upstream",
    });
    const merged = mergeCurated(cacheWith([upstreamSonnet]));
    const found = merged.models.filter((m) => m.id === SONNET);
    expect(found).toHaveLength(1);
    expect(found[0].label).toBe("from upstream");
  });
});

// ── Cost display ─────────────────────────────────────────────────────────────

describe("cost for a curated entry", () => {
  it("is null, not zero", () => {
    const { catalog } = effectiveCatalog();
    const sonnet = catalog.models.find((m) => m.id === SONNET)!;
    expect(computeSummaryCost(sonnet, 100_000, 5_000)).toBeNull();
  });

  it("reads as a pointer at OpenRouter rather than a dollar figure", () => {
    const { catalog } = effectiveCatalog();
    expect(costNoteFor(catalog, SONNET)).toBe("refer to OpenRouter");
    // A priced model has no note, and an unknown model is a different thing:
    // unknown cost, already rendered as "—".
    expect(costNoteFor(catalog, "gpt-5-mini")).toBeUndefined();
    expect(costNoteFor(catalog, "no-such-model")).toBeUndefined();
  });
});

// ── Settings + diagnostics ───────────────────────────────────────────────────

describe("nota settings set summary.model <namespaced id>", () => {
  it("validates through the registry with no special casing", () => {
    const file = path.join(
      mkdtempSync(path.join(tmpdir(), "nota-openrouter-settings-")),
      "settings.json",
    );
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    const stdout: string[] = [];
    vi.spyOn(process.stdout, "write").mockImplementation((chunk: unknown) => {
      stdout.push(String(chunk));
      return true;
    });
    try {
      settingsSet("summary.model", SONNET, file);
      expect(JSON.parse(readFileSync(file, "utf-8"))).toEqual({
        summary: { model: SONNET },
      });
      settingsGet("summary.model", file);
      expect(stdout.join("")).toBe(`${SONNET}\n`);

      expect(() => settingsSet("summary.model", "openrouter/nope", file)).toThrow(
        /Unknown summary model/,
      );
    } finally {
      stderr.mockRestore();
      vi.restoreAllMocks();
    }
  });
});

describe("nota config", () => {
  it("shows the OpenRouter key row like every other provider key", async () => {
    const originalEnv = process.env;
    process.env = {
      ...originalEnv,
      NOTA_ENV_FILE: path.join(tmpdir(), "nota-openrouter-config-absent"),
    };
    delete process.env.OPENROUTER_API_KEY;
    const stdout: string[] = [];
    vi.spyOn(process.stdout, "write").mockImplementation((chunk: unknown) => {
      stdout.push(String(chunk));
      return true;
    });
    vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    try {
      // Stub the CLI probe: this test is about a key row, and the real probe
      // would spawn whatever `claude`/`codex` happen to be on the machine.
      await printConfig({
        probe: async (provider) => ({
          provider,
          binary: provider === "codex" ? "codex" : "claude",
          found: false,
          detail: "stubbed",
        }),
      });
      expect(stdout.join("")).toContain("OPENROUTER_API_KEY\tabsent\tabsent");
    } finally {
      process.env = originalEnv;
      vi.restoreAllMocks();
    }
  });
});

// ── Request shape ────────────────────────────────────────────────────────────

describe("the output cap sent to OpenRouter", () => {
  it("is max_tokens, the parameter every OpenRouter route accepts", () => {
    // OpenRouter *drops* a parameter the chosen route does not support instead
    // of erroring, so `max_completion_tokens` here is worse than a failure: the
    // cap silently does not apply and only the bill says so.
    expect(summaryTokenLimit("anthropic/claude-sonnet-5", 4096, OPENROUTER_BASE_URL)).toEqual({
      max_tokens: 4096,
    });
  });

  it("is decided by the endpoint, because the wire id no longer names a provider", () => {
    const wire = requireModel(SONNET, "summary").wireId;
    // The id that goes on the wire is not a model the registry can look up —
    // its namespace was stripped precisely so OpenRouter would accept it.
    expect(getModel(wire)).toBeUndefined();
    expect(usesMaxTokensParam(wire, OPENROUTER_BASE_URL)).toBe(true);
    // Without the base URL there is nothing left to decide on, which is why
    // every caller passes it.
    expect(usesMaxTokensParam(wire, undefined)).toBe(false);
  });

  it("leaves OpenAI and DeepSeek on max_completion_tokens", () => {
    expect(summaryTokenLimit("gpt-5-mini", 1)).toEqual({ max_completion_tokens: 1 });
    expect(summaryTokenLimit("deepseek-v4-flash", 1, DEEPSEEK_BASE_URL)).toEqual({
      max_completion_tokens: 1,
    });
  });

  it("leaves Gemini on max_tokens whether or not the base URL is passed", () => {
    expect(summaryTokenLimit("gemini-2.5-flash", 8)).toEqual({ max_tokens: 8 });
    expect(summaryTokenLimit("gemini-2.5-flash", 8, GEMINI_OPENAI_BASE_URL)).toEqual({
      max_tokens: 8,
    });
  });
});

describe("providerForBaseURL", () => {
  it("names the provider each OpenAI-compatible endpoint belongs to", () => {
    expect(providerForBaseURL(OPENROUTER_BASE_URL)).toBe("openrouter");
    expect(providerForBaseURL(DEEPSEEK_BASE_URL)).toBe("deepseek");
    expect(providerForBaseURL(GEMINI_OPENAI_BASE_URL)).toBe("gemini");
    // The SDK may hand back the URL with or without its trailing slash.
    expect(providerForBaseURL(`${OPENROUTER_BASE_URL}/`)).toBe("openrouter");
    expect(providerForBaseURL(GEMINI_OPENAI_BASE_URL.replace(/\/$/, ""))).toBe("gemini");
  });

  it("is undefined for OpenAI's own endpoint (expressed as no base URL) and for strangers", () => {
    expect(providerForBaseURL(undefined)).toBeUndefined();
    expect(providerForBaseURL("")).toBeUndefined();
    expect(providerForBaseURL("https://api.openai.com/v1")).toBeUndefined();
  });
});
