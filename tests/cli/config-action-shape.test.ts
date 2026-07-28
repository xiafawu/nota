/**
 * `printConfig` is Commander's action handler for `nota config`, and Commander
 * invokes an action with `(options, command)`. When the CLI-engine probe was a
 * bare parameter with a default, Commander's own options object landed in it and
 * every real `nota config` died with "probe is not a function" — while the tests,
 * which always passed a probe, stayed green.
 *
 * So: the seam is a field on an options bag, and this file calls the function
 * the way Commander does.
 */

import { describe, expect, it, vi } from "vitest";

vi.mock("../../src/pipeline/cli-engine.js", async (importActual) => ({
  ...(await importActual<typeof import("../../src/pipeline/cli-engine.js")>()),
  // The default path must not spawn whatever `claude`/`codex` happen to be on
  // the machine running the suite.
  probeCliEngine: vi.fn(async (provider: "claude-code" | "codex") => ({
    provider,
    binary: provider === "codex" ? "codex" : "claude",
    found: false,
    detail: "probed by the default",
  })),
}));

import { printConfig } from "../../src/cli/config.js";
import { probeCliEngine } from "../../src/pipeline/cli-engine.js";

describe("nota config as Commander calls it", () => {
  it("survives an options object it does not recognize, and still probes", async () => {
    const stdout: string[] = [];
    vi.spyOn(process.stdout, "write").mockImplementation((chunk: unknown) => {
      stdout.push(String(chunk));
      return true;
    });
    vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    try {
      // Exactly what Commander hands an action that declares no options.
      await printConfig({} as Parameters<typeof printConfig>[0]);
      expect(probeCliEngine).toHaveBeenCalledTimes(2);
      expect(stdout.join("")).toContain("probed by the default");
    } finally {
      vi.restoreAllMocks();
    }
  });
});
