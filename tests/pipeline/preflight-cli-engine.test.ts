import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// Every outbound leg is stubbed: this file is about which check runs for a
// `cli` summary model, not about the network.
vi.mock("../../src/pipeline/summarize.js", async (importActual) => ({
  ...(await importActual<typeof import("../../src/pipeline/summarize.js")>()),
  canarySummaryModel: vi.fn(),
}));
vi.mock("../../src/pipeline/assemblyai.js", () => ({
  canaryAssemblyAI: vi.fn(async () => undefined),
}));
vi.mock("../../src/utils/ffmpeg.js", () => ({
  checkFfmpeg: vi.fn(async () => undefined),
}));
vi.mock("../../src/pipeline/embed.js", () => ({
  isIdentityAvailable: vi.fn(async () => false),
}));

import { runPreflight } from "../../src/pipeline/preflight.js";
import { canarySummaryModel } from "../../src/pipeline/summarize.js";
import { cliEngineFor } from "../../src/pipeline/cli-engine.js";
import { requireModel } from "../../src/registry.js";
import type { AppConfig } from "../../src/config.js";

const SONNET = "claude-code/sonnet";

function configFor(summaryModel: string): AppConfig {
  const entry = requireModel(summaryModel, "summary");
  const cli = cliEngineFor(entry);
  return {
    provider: "assemblyai",
    transcriptionModel: "universal",
    summaryModel: entry.id,
    summaryWireModel: entry.wireId,
    transcriptionApiKey: "aai-key",
    // A CLI engine resolves with no key, which must not read as "unconfigured".
    summaryApiKey: cli ? "" : "summary-key",
    summaryBaseURL: entry.baseURL,
    summaryCliEngine: cli,
    verbose: false,
    diarize: true,
    summary: true,
    identify: false,
    history: false,
    force: false,
    skipPreflight: false,
    verifySpeakers: false,
  };
}

let binDir: string;
let originalPath: string | undefined;

function fakeBinary(name: string, body: string): void {
  const file = path.join(binDir, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`, "utf-8");
  chmodSync(file, 0o755);
}

beforeEach(() => {
  binDir = mkdtempSync(path.join(tmpdir(), "nota-preflight-bin-"));
  originalPath = process.env.PATH;
  vi.mocked(canarySummaryModel).mockReset().mockResolvedValue(undefined);
});

afterEach(() => {
  process.env.PATH = originalPath;
  rmSync(binDir, { recursive: true, force: true });
});

describe("preflight for a CLI summary engine", () => {
  it("probes the binary instead of spending a summary call", async () => {
    fakeBinary("claude", 'echo "2.1.220 (Claude Code)"');
    process.env.PATH = `${binDir}${path.delimiter}${originalPath ?? ""}`;

    const result = await runPreflight(configFor(SONNET));
    const summary = result.checks.find((c) => c.id === "summary")!;

    expect(summary.status).toBe("ok");
    expect(summary.detail).toContain("2.1.220");
    // A canary here would cost minutes of wall time on every run, for a gate
    // whose whole purpose is to be cheaper than what it guards.
    expect(canarySummaryModel).not.toHaveBeenCalled();
    expect(result.overall).toBe("ready");
  });

  it("says out loud that a stale login is not what it checked", async () => {
    fakeBinary("claude", 'echo "2.1.220 (Claude Code)"');
    process.env.PATH = `${binDir}${path.delimiter}${originalPath ?? ""}`;

    const result = await runPreflight(configFor(SONNET));
    const summary = result.checks.find((c) => c.id === "summary")!;
    expect(summary.detail).toContain("login is not probed");
  });

  it("blocks the run when the binary is not installed", async () => {
    process.env.PATH = binDir;

    const result = await runPreflight(configFor(SONNET));
    const summary = result.checks.find((c) => c.id === "summary")!;

    expect(summary.status).toBe("fail");
    expect(summary.blocking).toBe(true);
    expect(summary.detail).toMatch(/claude not found on PATH — install Claude Code/);
    expect(result.overall).toBe("blocked");
  });

  it("does not read the empty API key as a missing one", async () => {
    process.env.PATH = binDir;
    const result = await runPreflight(configFor(SONNET));
    const summary = result.checks.find((c) => c.id === "summary")!;
    // The failure is about a binary, not about an env var that was never
    // going to exist for this model.
    expect(summary.detail).not.toContain("not set (env or ~/.nota/config)");
  });

  it("leaves the HTTP canary in charge of every http model", async () => {
    await runPreflight(configFor("gpt-5-mini"));
    expect(canarySummaryModel).toHaveBeenCalledWith("summary-key", "gpt-5-mini", undefined);
  });
});
