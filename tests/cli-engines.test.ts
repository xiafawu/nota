/**
 * CLI engines as *registry citizens* (ADR 0003): how they are admitted, what
 * they are allowed to be chosen for, and what they may never be chosen for.
 *
 * The subprocess itself is covered in `tests/pipeline/cli-engine.test.ts`.
 * Nothing here spawns a binary — where presence matters, a fake one is put on
 * PATH; where a probe would run, it is stubbed.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

import {
  CLI_BINARY,
  CLI_COST_NOTE,
  CLI_ENGINE_MODELS,
  CLI_PROVIDERS,
} from "../src/cli-engines.js";
import {
  computeSummaryCost,
  costNoteFor,
  effectiveCatalog,
  refreshCatalog,
  type CatalogCache,
} from "../src/catalog.js";
import {
  getModel,
  httpModelsForTask,
  modelsForTask,
  requireModel,
  requiresApiKey,
} from "../src/registry.js";
import { loadConfig } from "../src/config.js";
import { printConfig } from "../src/cli/config.js";
import { modelsList } from "../src/cli/models.js";
import { settingsSet } from "../src/cli/settings.js";
import { makeSummaryUsage } from "../src/pricing.js";
import { perModelSummary } from "../src/usage-stats.js";
import type { HistoryRecord } from "../src/pipeline/history.js";

const SONNET = "claude-code/sonnet";
const CODEX_SOL = "codex/gpt-5.6-sol";

// ── The shortlist ────────────────────────────────────────────────────────────

describe("the CLI-engine shortlist", () => {
  it("is namespaced, unpriced, cli-execution summary entries", () => {
    expect(CLI_ENGINE_MODELS.length).toBeGreaterThan(0);
    for (const m of CLI_ENGINE_MODELS) {
      expect(m.task).toBe("summary");
      expect(m.execution).toBe("cli");
      expect(m.origin).toBe("cli");
      expect(CLI_PROVIDERS).toContain(m.provider as (typeof CLI_PROVIDERS)[number]);
      expect(m.id.startsWith(`${m.provider}/`)).toBe(true);
      // A subscription has no per-token rate. Absent is not zero.
      expect(m.cost).toBeUndefined();
      expect(m.costNote).toBe(CLI_COST_NOTE);
    }
  });

  it("carries the ids the installed CLIs actually accept", () => {
    // Verified 2026-07-28: `claude --model` documents the tier aliases;
    // `codex exec -m` takes a slug from the CLI's own listed model set.
    expect(CLI_ENGINE_MODELS.map((m) => m.id)).toEqual([
      "claude-code/sonnet",
      "claude-code/opus",
      "claude-code/haiku",
      "codex/gpt-5.6-sol",
      "codex/gpt-5.6-terra",
      "codex/gpt-5.6-luna",
      "codex/gpt-5.4-mini",
    ]);
  });
});

// ── Registry resolution ──────────────────────────────────────────────────────

describe("registry resolution of a CLI engine id", () => {
  it("derives the provider from the namespace and asks for no key", () => {
    const entry = requireModel(SONNET, "summary");
    expect(entry.provider).toBe("claude-code");
    expect(entry.execution).toBe("cli");
    expect(entry.baseURL).toBeUndefined();
    expect(requiresApiKey(entry)).toBe(false);
  });

  it("strips the namespace to whatever the CLI's own flag expects", () => {
    expect(requireModel(SONNET, "summary").wireId).toBe("sonnet");
    expect(requireModel(CODEX_SOL, "summary").wireId).toBe("gpt-5.6-sol");
  });

  it("lists them among the summary models", () => {
    const ids = modelsForTask("summary").map((m) => m.id);
    for (const m of CLI_ENGINE_MODELS) expect(ids).toContain(m.id);
  });
});

describe("httpModelsForTask", () => {
  it("excludes every CLI engine, structurally", () => {
    // This is the mechanism ADR 0002 mandates and the one the dictation polish
    // picker uses: a subprocess engine cannot reach a per-sentence streaming
    // path because it fails an execution-kind test, not an id-prefix test.
    const http = httpModelsForTask("summary");
    expect(http.every((m) => m.execution === "http")).toBe(true);
    for (const m of CLI_ENGINE_MODELS) {
      expect(http.map((h) => h.id)).not.toContain(m.id);
    }
    // And they are genuinely in the catalog — the exclusion is a filter, not
    // an absence.
    expect(getModel(SONNET)).toBeDefined();
  });
});

// ── Admission survives a refresh ─────────────────────────────────────────────

describe("a catalog refresh cannot remove a CLI engine", () => {
  const originalCatalogPath = process.env.NOTA_CATALOG_PATH;
  let cachePath: string;

  beforeEach(() => {
    cachePath = path.join(
      mkdtempSync(path.join(tmpdir(), "nota-cli-engine-catalog-")),
      "models-catalog.json",
    );
    process.env.NOTA_CATALOG_PATH = cachePath;
  });

  afterEach(() => {
    process.env.NOTA_CATALOG_PATH = originalCatalogPath;
    vi.unstubAllGlobals();
  });

  it("writes only auto-admitted ids and still serves the engines", async () => {
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
    vi.stubGlobal("fetch", async () =>
      new Response(JSON.stringify(upstream), {
        status: 200,
        headers: { "content-type": "application/json", etag: '"fresh"' },
      }),
    );

    const result = await refreshCatalog();
    expect(result.ok).toBe(true);

    const written = JSON.parse(readFileSync(cachePath, "utf-8")) as CatalogCache;
    for (const m of CLI_ENGINE_MODELS) {
      // The engines live in code, so the cache has never held them and a
      // refresh has nothing to remove.
      expect(written.models.map((w) => w.id)).not.toContain(m.id);
      expect(result.removed).not.toContain(m.id);
    }

    const { catalog } = effectiveCatalog();
    for (const m of CLI_ENGINE_MODELS) {
      expect(catalog.models.map((x) => x.id)).toContain(m.id);
    }
  });
});

// ── Never a default ──────────────────────────────────────────────────────────

describe("the key-aware default chain", () => {
  let envBackup: NodeJS.ProcessEnv;
  let binDir: string;

  beforeEach(() => {
    envBackup = process.env;
    binDir = mkdtempSync(path.join(tmpdir(), "nota-chain-bin-"));
    // Both engines are installed and working, which is exactly the situation
    // the rule is about.
    for (const provider of CLI_PROVIDERS) {
      const file = path.join(binDir, CLI_BINARY[provider]);
      writeFileSync(file, "#!/bin/sh\necho 1.0.0\n", "utf-8");
      chmodSync(file, 0o755);
    }
    process.env = {
      ...envBackup,
      PATH: `${binDir}${path.delimiter}${envBackup.PATH ?? ""}`,
      NOTA_ENV_FILE: path.join(binDir, "no-such-config"),
    };
    delete process.env.DEEPSEEK_API_KEY;
    delete process.env.OPENAI_API_KEY;
    delete process.env.GEMINI_API_KEY;
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
  });

  afterEach(() => {
    process.env = envBackup;
    rmSync(binDir, { recursive: true, force: true });
  });

  it("is unchanged when both CLI binaries are present and working", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    const config = loadConfig({}, {});
    // "Free but slow" never wins a default, however available it is.
    expect(config.summaryModel).toBe("gpt-5.4-mini");
    expect(config.summaryCliEngine).toBeUndefined();
  });

  it("errors listing API models rather than falling back to a subprocess", () => {
    // With no summary key at all, offering an installed CLI as the rescue would
    // make it the effective default on every machine without a key.
    expect(() => loadConfig({}, {})).toThrow(/No summary model available/);
    try {
      loadConfig({}, {});
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      expect(message).not.toContain("claude-code");
      expect(message).not.toContain("codex");
    }
  });

  it("is chosen only when the owner says so, and then needs no key", () => {
    const config = loadConfig({ model: SONNET }, {});
    expect(config.summaryModel).toBe(SONNET);
    expect(config.summaryWireModel).toBe("sonnet");
    expect(config.summaryApiKey).toBe("");
    expect(config.summaryBaseURL).toBeUndefined();
    expect(config.summaryCliEngine).toEqual({
      provider: "claude-code",
      model: "sonnet",
    });
  });
});

// ── Settings ─────────────────────────────────────────────────────────────────

describe("nota settings set summary.model <cli engine>", () => {
  it("validates through the registry with no special casing", () => {
    const file = path.join(
      mkdtempSync(path.join(tmpdir(), "nota-cli-engine-settings-")),
      "settings.json",
    );
    const stderr = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    try {
      settingsSet("summary.model", CODEX_SOL, file);
      expect(JSON.parse(readFileSync(file, "utf-8"))).toEqual({
        summary: { model: CODEX_SOL },
      });
      expect(() => settingsSet("summary.model", "codex/not-a-model", file)).toThrow(
        /Unknown summary model/,
      );
    } finally {
      stderr.mockRestore();
    }
  });
});

// ── Cost ─────────────────────────────────────────────────────────────────────

describe("what a CLI-engine run costs", () => {
  it("is not zero, and not a figure — it is a note", () => {
    const { catalog } = effectiveCatalog();
    const entry = catalog.models.find((m) => m.id === SONNET)!;
    expect(computeSummaryCost(entry, 100_000, 5_000)).toBeNull();
    expect(costNoteFor(catalog, SONNET)).toBe("included w/ subscription");
    expect(costNoteFor(catalog, CODEX_SOL)).toBe("included w/ subscription");
  });

  it("records estimated token counts, because a subprocess reports none", () => {
    const usage = makeSummaryUsage(SONNET, "assemblyai", {
      calls: 2,
      tokensIn: 40_000,
      tokensOut: 900,
    });
    expect(usage.costUSD).toBeNull();
    expect(usage.estimated).toBe(true);
    // A priced HTTP model still reports the provider's own numbers.
    expect(
      makeSummaryUsage("gpt-5-mini", "assemblyai", {
        calls: 1,
        tokensIn: 10,
        tokensOut: 10,
      }).estimated,
    ).toBe(false);
  });

  it("stays out of the unknown-cost tally and carries the note into the row", () => {
    // "unknown cost" flags a gap in Nota's own data. A subscription run is not
    // a gap — the price is known and it is zero marginal, which is why it gets
    // a note instead of a "—".
    const record = {
      id: "cli-run",
      createdAt: "2026-07-15T12:00:00.000Z",
      updatedAt: "2026-07-15T12:01:00.000Z",
      capturedAt: null,
      sourcePath: "/tmp/a.m4a",
      sourceName: "a.m4a",
      durationMinutes: 5,
      transcriptText: "hi",
      segments: [],
      status: "completed",
      provider: "assemblyai",
      usage: [
        {
          modelId: SONNET,
          task: "summary",
          provider: "assemblyai",
          calls: 1,
          tokensIn: 40_000,
          tokensOut: 900,
          costUSD: null,
          estimated: true,
        },
      ],
    } as unknown as HistoryRecord;

    const [row] = perModelSummary([record]);
    expect(row.modelId).toBe(SONNET);
    expect(row.costNote).toBe("included w/ subscription");
    expect(row.costUSD).toBe(0);
  });
});

// ── Diagnostics ──────────────────────────────────────────────────────────────

describe("nota models list", () => {
  it("marks a CLI engine's source as cli", async () => {
    const stdout: string[] = [];
    vi.spyOn(process.stdout, "write").mockImplementation((chunk: unknown) => {
      stdout.push(String(chunk));
      return true;
    });
    vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    try {
      await modelsList();
      const rows = stdout.join("").split("\n");
      const sonnet = rows.find((r) => r.startsWith(`${SONNET}\t`))!;
      expect(sonnet.split("\t")[3]).toBe("cli");
      // The OpenRouter shortlist keeps its own marker; the auto half keeps the
      // catalog's.
      const openrouter = rows.find((r) =>
        r.startsWith("openrouter/anthropic/claude-sonnet-5\t"),
      )!;
      expect(openrouter.split("\t")[3]).toBe("curated");
      const auto = rows.find((r) => r.startsWith("gpt-5-mini\t"))!;
      expect(auto.split("\t")[3]).toBe("baked");
    } finally {
      vi.restoreAllMocks();
    }
  });
});

describe("nota config", () => {
  it("reports each engine's binary and version alongside the key rows", async () => {
    const stdout: string[] = [];
    const stderr: string[] = [];
    vi.spyOn(process.stdout, "write").mockImplementation((chunk: unknown) => {
      stdout.push(String(chunk));
      return true;
    });
    vi.spyOn(process.stderr, "write").mockImplementation((chunk: unknown) => {
      stderr.push(String(chunk));
      return true;
    });
    try {
      await printConfig(async (provider) => ({
        provider,
        binary: CLI_BINARY[provider],
        found: provider === "claude-code",
        path: provider === "claude-code" ? "/usr/local/bin/claude" : undefined,
        version: provider === "claude-code" ? "2.1.220 (Claude Code)" : undefined,
        detail:
          provider === "claude-code"
            ? "2.1.220 (Claude Code) at /usr/local/bin/claude"
            : "codex not found on PATH — install Codex CLI",
      }));
      const out = stdout.join("");
      expect(out).toContain("claude-code\tclaude\t2.1.220 (Claude Code) at /usr/local/bin/claude");
      expect(out).toContain("codex\tcodex\tcodex not found on PATH");
      // The block says why there is no key column for these rows.
      expect(stderr.join("")).toContain("CLI summary engines (no API key");
    } finally {
      vi.restoreAllMocks();
    }
  });
});
