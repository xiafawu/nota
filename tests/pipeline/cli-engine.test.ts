/**
 * The subprocess summary engine (ADR 0003), exercised end to end against a
 * **fake** binary: a shell script on a temp PATH that records what it was given
 * and answers however the test needs.
 *
 * The real `claude` and `codex` are never spawned here. They cost subscription
 * quota, they take minutes, and their answers are not deterministic — none of
 * which a unit test may depend on. What the real binaries *do* accept was
 * verified by hand against `claude --version` 2.1.220 and `codex-cli 0.144.0`
 * on 2026-07-28, and is asserted below as the argument vector this module
 * builds.
 */

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

import {
  CLI_AUTH_SNIFF_MAX_CHARS,
  CLI_TIMEOUT_BASE_MS,
  CLI_TIMEOUT_MAX_MS,
  cleanCliOutput,
  cliArgs,
  cliEngineFor,
  cliTimeoutMs,
  firstVersionLine,
  formatWait,
  isAuthComplaint,
  isDeniedEnvKey,
  looksUnauthenticated,
  notaCodexHome,
  prepareCodexHome,
  probeCliEngine,
  realCodexHome,
  resolveBinaryPath,
  runCliPrompt,
  sanitizedEnv,
  type CliEngineSpec,
} from "../../src/pipeline/cli-engine.js";
import { requireModel } from "../../src/registry.js";
import { summarizeTranscript } from "../../src/pipeline/summarize.js";

const SONNET: CliEngineSpec = { provider: "claude-code", model: "sonnet" };

const SUMMARY_ANSWER = [
  "### Title",
  "Quarterly planning sync",
  "",
  "### Summary",
  "They agreed on the roadmap.",
  "",
  "### Key Topics",
  "- **Roadmap** — next quarter",
  "",
  "### Decisions Made",
  "- Ship in March — the customer asked",
  "",
  "### Action Items",
  "- [ ] Draft the plan — assigned to Ada",
  "",
  "### Tags",
  "planning, roadmap",
].join("\n");

let binDir: string;
let stateDir: string;
let originalPath: string | undefined;

/** Write an executable shell script into the fake PATH directory. */
function fakeBinary(name: string, body: string): void {
  const file = path.join(binDir, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`, "utf-8");
  chmodSync(file, 0o755);
}

/**
 * A fake that records argv, stdin and its inherited environment, then prints
 * `SUMMARY_ANSWER`. Every capture path is absolute so the script does not care
 * that the child runs in a scratch cwd.
 */
function fakeSuccessBinary(name: string): void {
  fakeBinary(
    name,
    [
      `printf '%s\\n' "$@" > "${stateDir}/argv"`,
      `cat > "${stateDir}/stdin"`,
      `env > "${stateDir}/env"`,
      `echo call >> "${stateDir}/calls"`,
      `cat <<'NOTA_EOF'`,
      SUMMARY_ANSWER,
      `NOTA_EOF`,
    ].join("\n"),
  );
}

beforeEach(() => {
  binDir = mkdtempSync(path.join(tmpdir(), "nota-fake-bin-"));
  stateDir = mkdtempSync(path.join(tmpdir(), "nota-fake-state-"));
  originalPath = process.env.PATH;
  process.env.PATH = `${binDir}${path.delimiter}${originalPath ?? ""}`;
});

afterEach(() => {
  process.env.PATH = originalPath;
  delete process.env.ANTHROPIC_API_KEY;
  delete process.env.CLAUDECODE;
  delete process.env.OPENAI_API_KEY;
  rmSync(binDir, { recursive: true, force: true });
  rmSync(stateDir, { recursive: true, force: true });
});

function capture(name: string): string {
  const file = path.join(stateDir, name);
  return existsSync(file) ? readFileSync(file, "utf-8") : "";
}

// ── The invocation ───────────────────────────────────────────────────────────

describe("the argument vector", () => {
  it("is claude's print mode with tools off, model on the flag", () => {
    expect(cliArgs(SONNET)).toEqual([
      "-p",
      "--safe-mode",
      "--model",
      "sonnet",
      "--output-format",
      "text",
      "--tools",
      "",
    ]);
  });

  it("is codex's exec subcommand reading its prompt from stdin", () => {
    expect(cliArgs({ provider: "codex", model: "gpt-5.6-sol" })).toEqual([
      "exec",
      "-m",
      "gpt-5.6-sol",
      "--sandbox",
      "read-only",
      "--skip-git-repo-check",
      "--ignore-user-config",
      "--color",
      "never",
      "-",
    ]);
  });

  it("turns off each CLI's user-level instruction discovery", () => {
    // The scratch cwd only stops *project* discovery. `~/.claude/CLAUDE.md` and
    // `$CODEX_HOME/AGENTS.md` load from the home directory whatever the cwd, and
    // without these flags the owner's personal agent guide is prepended to every
    // meeting summary (measured against both installed binaries, 2026-07-28).
    expect(cliArgs(SONNET)).toContain("--safe-mode");
    // Not `--bare`: it disables the same discovery but forces auth onto
    // ANTHROPIC_API_KEY, i.e. the metered account this path exists to avoid.
    expect(cliArgs(SONNET)).not.toContain("--bare");
    expect(cliArgs({ provider: "codex", model: "gpt-5.4-mini" })).toContain(
      "--ignore-user-config",
    );
    // `--ignore-rules` would loosen an execpolicy rail the owner set, not
    // remove an instruction, so it is deliberately absent.
    expect(cliArgs({ provider: "codex", model: "gpt-5.4-mini" })).not.toContain(
      "--ignore-rules",
    );
  });

  it("carries the wire id the CLI's flag expects, not the canonical id", () => {
    // `claude --model claude-code/sonnet` is not a model; `sonnet` is.
    const entry = requireModel("claude-code/sonnet", "summary");
    expect(entry.id).toBe("claude-code/sonnet");
    expect(cliEngineFor(entry)).toEqual({ provider: "claude-code", model: "sonnet" });
  });

  it("is undefined for an http model, so nothing can route one to a subprocess", () => {
    expect(cliEngineFor(requireModel("gpt-5-mini", "summary"))).toBeUndefined();
    expect(
      cliEngineFor(requireModel("openrouter/anthropic/claude-sonnet-5", "summary")),
    ).toBeUndefined();
  });
});

describe("a successful run", () => {
  it("returns the CLI's stdout as the completion", async () => {
    fakeSuccessBinary("claude");
    await expect(runCliPrompt(SONNET, "summarize this")).resolves.toBe(SUMMARY_ANSWER);
  });

  it("puts the prompt on stdin and never on argv", async () => {
    fakeSuccessBinary("claude");
    // Long enough that argv would be a real risk, and full of the characters
    // that make shell quoting a bug: quotes, backticks, newlines, `$`.
    const prompt = `don't \`run\` $this\n${"x".repeat(5_000)}`;
    await runCliPrompt(SONNET, prompt);

    expect(capture("stdin")).toBe(prompt);
    const argv = capture("argv");
    // `--tools`'s value is the empty string, which the capture's line-per-arg
    // form cannot distinguish from the trailing newline — hence the filter and
    // the missing seventh entry.
    expect(argv.split("\n").filter(Boolean)).toEqual([
      "-p",
      "--safe-mode",
      "--model",
      "sonnet",
      "--output-format",
      "text",
      "--tools",
    ]);
    expect(argv).not.toContain("x".repeat(50));
  });

  it("withholds credentials and agent-session state from the child", async () => {
    fakeSuccessBinary("claude");
    process.env.ANTHROPIC_API_KEY = "sk-must-not-leak";
    process.env.OPENAI_API_KEY = "sk-also-not";
    process.env.CLAUDECODE = "1";

    await runCliPrompt(SONNET, "hi");

    const env = capture("env");
    // Leaking a key would bill a metered account for a run whose cost line
    // says "included w/ subscription".
    expect(env).not.toContain("sk-must-not-leak");
    expect(env).not.toContain("sk-also-not");
    expect(env).not.toMatch(/^CLAUDECODE=/m);
    // What it still needs survives.
    expect(env).toMatch(/^PATH=/m);
  });
});

// ── Failure contract ─────────────────────────────────────────────────────────

describe("a missing binary", () => {
  it("fails hard, names the binary, and names the fix", async () => {
    // Nothing was written into the fake PATH dir, and the temp dir is first.
    await expect(
      runCliPrompt({ provider: "claude-code", model: "sonnet" }, "hi", {
        env: { PATH: binDir },
      }),
    ).rejects.toThrow(
      /claude not found on PATH — install Claude Code or choose an API model/,
    );
  });

  it("says plainly that nothing was substituted for it", async () => {
    await expect(
      runCliPrompt({ provider: "codex", model: "gpt-5.6-sol" }, "hi", {
        env: { PATH: binDir },
        codexHomeRoot: path.join(stateDir, "codex-home"),
      }),
    ).rejects.toThrow(/No API model was substituted/);
  });
});

describe("a non-zero exit", () => {
  it("surfaces the CLI's own stderr", async () => {
    fakeBinary("claude", 'cat > /dev/null\necho "boom: model overloaded" >&2\nexit 3');
    await expect(runCliPrompt(SONNET, "hi")).rejects.toThrow(
      /exited with code 3.*boom: model overloaded/s,
    );
  });

  it("is read as a missing login when the CLI says so", async () => {
    fakeBinary("claude", 'cat > /dev/null\necho "Not logged in." >&2\nexit 1');
    await expect(runCliPrompt(SONNET, "hi")).rejects.toThrow(
      /not authenticated — run `claude` once and sign in/,
    );
  });

  it("refuses a clean exit that produced nothing", async () => {
    // An empty answer parsed into a summary would be written over the user's
    // notes, so exit 0 is not on its own a success.
    fakeBinary("claude", "cat > /dev/null\nexit 0");
    await expect(runCliPrompt(SONNET, "hi")).rejects.toThrow(
      /exited cleanly but produced no output/,
    );
  });

  it("refuses a clean exit whose 'answer' is a login complaint", async () => {
    // Both CLIs report an expired login on the happy exit path, printing the
    // complaint where the summary should be. Resolving that would parse one
    // line into a summary and write it over the user's notes.
    fakeBinary(
      "claude",
      'cat > /dev/null\necho "Invalid API key · Please run /login"\nexit 0',
    );
    await expect(runCliPrompt(SONNET, "hi")).rejects.toThrow(
      /not authenticated — run `claude` once and sign in/,
    );
  });

  it("quotes what the CLI actually printed when only stdout carried it", async () => {
    fakeBinary("claude", 'cat > /dev/null\necho "Not logged in."\nexit 0');
    await expect(runCliPrompt(SONNET, "hi")).rejects.toThrow(/Not logged in\./);
  });

  it("does not mistake a summary that mentions a 401 for a failed login", async () => {
    // `looksUnauthenticated` matches "401" and "unauthorized"; a meeting is
    // allowed to have been about an HTTP status. The bound is what keeps the
    // sniff from eating real answers.
    const aboutAuth = SUMMARY_ANSWER.replace(
      "They agreed on the roadmap.",
      `They agreed on the roadmap. ${"The 401 unauthorized responses were the topic. ".repeat(12)}`,
    );
    expect(aboutAuth.length).toBeGreaterThan(CLI_AUTH_SNIFF_MAX_CHARS);
    fakeBinary(
      "claude",
      ["cat > /dev/null", "cat <<'NOTA_EOF'", aboutAuth, "NOTA_EOF"].join("\n"),
    );
    await expect(runCliPrompt(SONNET, "hi")).resolves.toBe(aboutAuth);
  });
});

describe("isAuthComplaint", () => {
  it("is true only for output short enough not to be a summary", () => {
    expect(isAuthComplaint("Please run /login")).toBe(true);
    expect(isAuthComplaint("", "session expired")).toBe(true);
    expect(isAuthComplaint(`401 unauthorized ${"x".repeat(CLI_AUTH_SNIFF_MAX_CHARS)}`)).toBe(
      false,
    );
    expect(isAuthComplaint("### Title\nSync")).toBe(false);
  });
});

describe("a timeout", () => {
  it("stops the process and says how long it waited", async () => {
    fakeBinary("claude", "cat > /dev/null\nsleep 30");
    await expect(
      runCliPrompt(SONNET, "hi", { timeoutMs: 1_000 }),
    ).rejects.toThrow(/did not finish within 1s \(waited 1s\)/);
  });
});

describe("the wait budget", () => {
  it("starts generous and grows with the prompt", () => {
    expect(cliTimeoutMs(0)).toBe(CLI_TIMEOUT_BASE_MS);
    expect(cliTimeoutMs(10_000)).toBeGreaterThan(CLI_TIMEOUT_BASE_MS);
    expect(cliTimeoutMs(400_000)).toBeGreaterThan(cliTimeoutMs(10_000));
  });

  it("is capped — past the ceiling something is wrong, not slow", () => {
    expect(cliTimeoutMs(100_000_000)).toBe(CLI_TIMEOUT_MAX_MS);
  });

  it("renders as minutes and seconds, which is what the error prints", () => {
    expect(formatWait(180_000)).toBe("3m0s");
    expect(formatWait(930_000)).toBe("15m30s");
    expect(formatWait(45_000)).toBe("45s");
  });
});

// ── Output handling ──────────────────────────────────────────────────────────

describe("cleanCliOutput", () => {
  it("keeps a summary's checkboxes intact", () => {
    // The ANSI pattern without its ESC anchor also matches `[ ]`, which would
    // silently delete every action item.
    expect(cleanCliOutput("- [ ] Draft the plan\n- [x] Done")).toBe(
      "- [ ] Draft the plan\n- [x] Done",
    );
  });

  it("strips escape codes a CLI emitted anyway", () => {
    expect(cleanCliOutput("\u001B[32m### Title\u001B[0m\nSync")).toBe("### Title\nSync");
  });

  it("unwraps a fence that encloses the whole answer", () => {
    expect(cleanCliOutput("```markdown\n### Title\nSync\n```")).toBe("### Title\nSync");
    // A fence *inside* the answer is content and stays.
    expect(cleanCliOutput("### Title\n```\ncode\n```\ntail")).toBe(
      "### Title\n```\ncode\n```\ntail",
    );
  });
});

describe("looksUnauthenticated", () => {
  it("recognizes the ways these CLIs say 'log in'", () => {
    expect(looksUnauthenticated("Not logged in")).toBe(true);
    expect(looksUnauthenticated("Please run codex login")).toBe(true);
    expect(looksUnauthenticated("401 Unauthorized")).toBe(true);
    expect(looksUnauthenticated("stream error: model overloaded")).toBe(false);
  });
});

// ── The Codex home jail ──────────────────────────────────────────────────────

describe("prepareCodexHome", () => {
  let realHome: string;
  let jail: string;

  beforeEach(() => {
    realHome = path.join(stateDir, "real-codex");
    jail = path.join(stateDir, "codex-home");
    mkdirSync(realHome, { recursive: true });
    writeFileSync(path.join(realHome, "auth.json"), '{"token":"real"}', "utf-8");
    // The things a summary run may not see.
    writeFileSync(path.join(realHome, "AGENTS.md"), "# Your personal guide", "utf-8");
    writeFileSync(path.join(realHome, "config.toml"), "model = 'nope'", "utf-8");
  });

  it("hands the child a home holding the login and nothing else", () => {
    // `codex` has no flag that excludes $CODEX_HOME/AGENTS.md — not
    // --ignore-user-config, not -c project_doc_max_bytes=0 (both measured
    // 2026-07-28). A different home is the only mechanism there is.
    const out = prepareCodexHome({ env: { CODEX_HOME: realHome }, root: jail });
    expect(out).toBe(jail);
    expect(readdirSync(jail)).toEqual(["auth.json"]);
    expect(readFileSync(path.join(jail, "auth.json"), "utf-8")).toBe('{"token":"real"}');
  });

  it("links the login rather than copying it, so a refresh is not stranded", () => {
    prepareCodexHome({ env: { CODEX_HOME: realHome }, root: jail });
    expect(lstatSync(path.join(jail, "auth.json")).isSymbolicLink()).toBe(true);
  });

  it("restores the link when a token refresh replaced it with a real file", () => {
    prepareCodexHome({ env: { CODEX_HOME: realHome }, root: jail });
    // What a write-and-rename token refresh leaves behind: a regular file
    // holding a credential, and a real auth.json that no longer gets updated.
    rmSync(path.join(jail, "auth.json"));
    writeFileSync(path.join(jail, "auth.json"), '{"token":"stranded"}', "utf-8");

    prepareCodexHome({ env: { CODEX_HOME: realHome }, root: jail });
    expect(lstatSync(path.join(jail, "auth.json")).isSymbolicLink()).toBe(true);
    expect(readFileSync(path.join(jail, "auth.json"), "utf-8")).toBe('{"token":"real"}');
  });

  it("leaves the jail loginless when there is no login to borrow", () => {
    // Better an honest "not authenticated — run `codex login`" than silently
    // reusing whatever an earlier run left here.
    prepareCodexHome({ env: { CODEX_HOME: realHome }, root: jail });
    rmSync(path.join(realHome, "auth.json"));
    prepareCodexHome({ env: { CODEX_HOME: realHome }, root: jail });
    expect(readdirSync(jail)).toEqual([]);
  });

  it("defaults to ~/.codex when the owner never moved it", () => {
    expect(realCodexHome({})).toBe(path.join(homedir(), ".codex"));
    expect(realCodexHome({ CODEX_HOME: "/elsewhere/codex" })).toBe("/elsewhere/codex");
    expect(notaCodexHome()).toBe(path.join(homedir(), ".nota", "codex-home"));
  });

  it("does nothing when the owner already points CODEX_HOME at the jail", () => {
    // Nothing to link and nothing to exclude — and above all nothing to delete.
    const out = prepareCodexHome({ env: { CODEX_HOME: realHome }, root: realHome });
    expect(out).toBe(realHome);
    expect(existsSync(path.join(realHome, "AGENTS.md"))).toBe(true);
    expect(readFileSync(path.join(realHome, "auth.json"), "utf-8")).toBe('{"token":"real"}');
  });
});

describe("the child's CODEX_HOME", () => {
  it("is the jail, not the owner's own", async () => {
    fakeSuccessBinary("codex");
    const jail = path.join(stateDir, "codex-home");
    await runCliPrompt({ provider: "codex", model: "gpt-5.4-mini" }, "hi", {
      codexHomeRoot: jail,
    });
    expect(capture("env")).toMatch(new RegExp(`^CODEX_HOME=${jail}$`, "m"));
  });

  it("is left alone for claude, which needs no jail", async () => {
    fakeSuccessBinary("claude");
    await runCliPrompt(SONNET, "hi");
    expect(capture("env")).not.toMatch(/^CODEX_HOME=/m);
  });
});

describe("sanitizedEnv", () => {
  it("drops session state and credentials, keeps everything else", () => {
    const out = sanitizedEnv({
      PATH: "/usr/bin",
      HOME: "/Users/x",
      CLAUDECODE: "1",
      CLAUDE_CODE_ENTRYPOINT: "cli",
      ANTHROPIC_API_KEY: "sk-x",
      CODEX_SANDBOX: "1",
      OPENAI_API_KEY: "sk-y",
      OPENROUTER_API_KEY: "sk-z",
    });
    expect(out).toEqual({ PATH: "/usr/bin", HOME: "/Users/x" });
  });

  it("keeps the two variables that say where the CLI's own login lives", () => {
    // Stripping these would leave the child unauthenticated for a reason
    // nothing on screen explains.
    expect(isDeniedEnvKey("CLAUDE_CONFIG_DIR")).toBe(false);
    expect(isDeniedEnvKey("CODEX_HOME")).toBe(false);
    expect(isDeniedEnvKey("CLAUDE_CODE_SSE_PORT")).toBe(true);
  });
});

// ── Sectioned mode ───────────────────────────────────────────────────────────

describe("a transcript too long for one call", () => {
  it("runs every section and the roll-up through the same engine", async () => {
    fakeSuccessBinary("claude");
    // Over the 100k-token chunking threshold, in lines the splitter can cut.
    const line = `Speaker 1: ${"word ".repeat(40)}`;
    const transcript = Array.from({ length: 3_000 }, () => line).join("\n");

    const { summary, tokenUsage } = await summarizeTranscript(
      transcript,
      "",
      "sonnet",
      undefined,
      undefined,
      SONNET,
    );

    const calls = capture("calls").split("\n").filter(Boolean).length;
    expect(calls).toBeGreaterThan(1);
    // Sections plus exactly one roll-up, and the reported call count agrees
    // with how many processes actually ran.
    expect(tokenUsage.calls).toBe(calls);
    expect(summary.title).toBe("Quarterly planning sync");
    // No usage comes back from a subprocess, so the counts are estimates —
    // present, non-zero, and marked estimated by `makeSummaryUsage`.
    expect(tokenUsage.tokensIn).toBeGreaterThan(0);
    expect(tokenUsage.tokensOut).toBeGreaterThan(0);
  }, 30_000);

  it("sends the same prompt the HTTP path would have sent", async () => {
    fakeSuccessBinary("claude");
    const { summary } = await summarizeTranscript(
      "Speaker 1: we shipped it.",
      "",
      "sonnet",
      undefined,
      undefined,
      SONNET,
    );
    const stdin = capture("stdin");
    expect(stdin).toContain("You are an expert meeting summarizer");
    expect(stdin).toContain("Speaker 1: we shipped it.");
    expect(stdin).toContain("### Action Items");
    expect(summary.actionItems).toEqual(["[ ] Draft the plan — assigned to Ada"]);
  });
});

// ── Diagnostics ──────────────────────────────────────────────────────────────

describe("probeCliEngine", () => {
  it("reports the version and the resolved path when the binary answers", async () => {
    fakeBinary("claude", 'echo "9.9.9 (Fake Claude Code)"');
    const probe = await probeCliEngine("claude-code");
    expect(probe.found).toBe(true);
    expect(probe.version).toBe("9.9.9 (Fake Claude Code)");
    expect(probe.path).toBe(path.join(binDir, "claude"));
    expect(probe.detail).toContain("9.9.9");
  });

  it("reports 'not found' without spawning anything", async () => {
    const probe = await probeCliEngine("codex", { env: { PATH: binDir } });
    expect(probe.found).toBe(false);
    expect(probe.path).toBeUndefined();
    expect(probe.detail).toMatch(/codex not found on PATH — install Codex CLI/);
  });

  it("reports the version from stdout, not whatever noise stderr made first", async () => {
    // `NODE_OPTIONS` survives `sanitizedEnv` (it is neither a credential nor
    // agent-session state), and the warnings it provokes land on stderr before
    // the version lands on stdout. Merged into one buffer, `nota config` prints
    // the warning as the CLI's version.
    fakeBinary(
      "claude",
      'echo "(node:1) ExperimentalWarning: VM Modules is experimental" >&2\necho "2.1.220 (Claude Code)"',
    );
    const probe = await probeCliEngine("claude-code");
    expect(probe.found).toBe(true);
    expect(probe.version).toBe("2.1.220 (Claude Code)");
    expect(probe.detail).not.toContain("ExperimentalWarning");
  });

  it("falls back to stderr only when stdout said nothing at all", () => {
    expect(firstVersionLine("\n\n1.2.3\ntrailing", "noise")).toBe("1.2.3");
    expect(firstVersionLine("   \n", "codex-cli 0.144.0")).toBe("codex-cli 0.144.0");
    expect(firstVersionLine("", "")).toBeUndefined();
  });

  it("is not a summary call — preflight may not spend minutes per run", async () => {
    // The probe asks only for `--version`; a fake that answers that and nothing
    // else is enough for a green check.
    fakeBinary("claude", 'if [ "$1" = "--version" ]; then echo "1.0.0"; else exit 9; fi');
    const probe = await probeCliEngine("claude-code");
    expect(probe.found).toBe(true);
  });
});

describe("resolveBinaryPath", () => {
  it("finds the first executable of that name on PATH", () => {
    fakeBinary("codex", "echo hi");
    expect(resolveBinaryPath("codex", { PATH: binDir })).toBe(path.join(binDir, "codex"));
    expect(resolveBinaryPath("nota-no-such-binary", { PATH: binDir })).toBeUndefined();
  });
});
