/**
 * The subprocess half of the summary path (ADR 0003).
 *
 * A `cli`-execution model is not an endpoint: it is `claude -p` or `codex exec`
 * on this machine. This module owns everything that differs from an HTTP call —
 * how the process is invoked, what it is allowed to inherit, how long we wait,
 * and what a failure says — so `summarize.ts` only has to choose between two
 * callers with the same shape.
 *
 * Four rules the rest of the pipeline depends on:
 *
 * 1. **The prompt goes on stdin, never on argv.** A meeting transcript is
 *    megabytes; `ARG_MAX` is not, and quoting a transcript into a command line
 *    is a bug waiting for the first apostrophe. Both CLIs read their prompt from
 *    stdin when none is given as an argument, which is exactly the contract we
 *    want. Nothing is inherited: stdin is a pipe we write and close, so a Nota
 *    run inside another agent's session cannot hand the child that session's
 *    terminal.
 * 2. **No key is passed and no session state is inherited.** See
 *    {@link sanitizedEnv}. Leaking `ANTHROPIC_API_KEY` into `claude` would bill
 *    a per-token API account for a run whose cost line says
 *    "included w/ subscription" — the report would be a lie, and the user would
 *    find out from an invoice.
 * 3. **No ambient instructions reach the model.** A scratch cwd is necessary and
 *    is *not* sufficient: both CLIs auto-discover a **user-level** guide
 *    (`~/.claude/CLAUDE.md`, `$CODEX_HOME/AGENTS.md`) plus skills, plugins and
 *    hooks from the home directory, whatever the cwd. A summary must depend on
 *    the transcript and nothing else; without the exclusions the owner's
 *    personal agent guide is prepended to every meeting summary. Claude Code has
 *    a flag for it ({@link cliArgs}); codex does not, and gets a private
 *    `CODEX_HOME` holding only its login ({@link prepareCodexHome}).
 * 4. **Every failure is hard and names its fix.** Missing binary, missing login,
 *    non-zero exit, timeout, empty output — all throw {@link CliEngineError}.
 *    There is deliberately no fallback to an HTTP model: falling back would
 *    silently bill a provider the user did not choose.
 */

import { spawn, type ChildProcess } from "node:child_process";
import {
  accessSync,
  constants,
  existsSync,
  mkdirSync,
  rmSync,
  symlinkSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import path from "node:path";

import {
  CLI_BINARY,
  CLI_LOGIN_HINT,
  CLI_PRODUCT,
  isCliProvider,
  type CliProvider,
} from "../cli-engines.js";
import type { ModelEntry } from "../registry.js";

/** What to run, and with which model. `model` is the entry's **wire** id. */
export interface CliEngineSpec {
  provider: CliProvider;
  /** Exactly what the CLI's `--model`/`-m` flag expects. */
  model: string;
}

/** Every CLI-engine failure. Never recoverable — there is no fallback path. */
export class CliEngineError extends Error {
  constructor(
    message: string,
    readonly provider: CliProvider,
  ) {
    super(message);
    this.name = "CliEngineError";
  }
}

/**
 * The CLI engine a registry entry names, or `undefined` for every HTTP model.
 * Decided on the execution kind — the id is never pattern-matched (ADR 0002).
 */
export function cliEngineFor(entry: ModelEntry): CliEngineSpec | undefined {
  if (entry.execution !== "cli") return undefined;
  if (!isCliProvider(entry.provider)) return undefined;
  return { provider: entry.provider, model: entry.wireId };
}

/** The canonical model id a spec came from, for error messages. */
export function engineLabel(spec: CliEngineSpec): string {
  return `${spec.provider}/${spec.model}`;
}

// ── Invocation ───────────────────────────────────────────────────────────────

/**
 * The argument vector for one non-interactive completion.
 *
 * Verified against `claude --help` (2.1.220) and `codex exec --help` (0.144.0)
 * on 2026-07-28. Every flag earns its place:
 *
 * - `claude -p` is print mode: answer once, exit, no TUI.
 * - `claude --output-format text` is the plain-text contract this module
 *   promises its caller; `json` and `stream-json` would need a parser.
 * - `claude --tools ""` disables every built-in tool. A summarizer needs none,
 *   and a model that cannot read or write files cannot touch the user's disk,
 *   stall on a permission prompt, or interleave tool chatter into stdout.
 * - `claude --safe-mode` is what actually keeps the owner's agent guide out of
 *   the prompt. The cwd rule (module rule 3) only stops *project* discovery;
 *   `~/.claude/CLAUDE.md`, skills, plugins, hooks and MCP servers load from the
 *   home directory whatever the cwd — measured 2026-07-28 from `tmpdir()`, where
 *   the model quoted this machine's global guide back verbatim, and did not
 *   under `--safe-mode`. `--bare` disables the same things and was **rejected**:
 *   its own help says auth becomes "strictly ANTHROPIC_API_KEY or apiKeyHelper",
 *   which is the metered account module rule 2 exists to keep out of a run
 *   billed "included w/ subscription". `--safe-mode` leaves auth alone.
 * - `codex exec` is its non-interactive subcommand; the trailing `-` says the
 *   prompt is on stdin. Its session preamble goes to **stderr** and the final
 *   message alone to stdout, which is why stdout needs no de-noising.
 * - `codex --sandbox read-only` is the same refusal as `--tools ""`: the agent
 *   may not write. `--skip-git-repo-check` is required because we run in a
 *   scratch cwd, and `--color never` keeps escape codes out of the answer.
 * - `codex --ignore-user-config` drops `config.toml` and the plugins and hooks
 *   it turns on, and its own help promises "auth still uses `CODEX_HOME`". It is
 *   **not** sufficient on its own: measured on 2026-07-28 by asking the model to
 *   list the headings in its context, `$CODEX_HOME/AGENTS.md` was still loaded
 *   with this flag set, and with `-c project_doc_max_bytes=0` on top of it. That
 *   file is excluded by {@link prepareCodexHome} instead; the flag stays as the
 *   cheap half of the same job.
 *   `--ignore-rules` was **not** added — execpolicy `.rules` files only ever
 *   restrict what a shell command may do, so ignoring them loosens a rail the
 *   owner set rather than removing an instruction.
 */
export function cliArgs(spec: CliEngineSpec): string[] {
  switch (spec.provider) {
    case "claude-code":
      return [
        "-p",
        "--safe-mode",
        "--model",
        spec.model,
        "--output-format",
        "text",
        "--tools",
        "",
      ];
    case "codex":
      return [
        "exec",
        "-m",
        spec.model,
        "--sandbox",
        "read-only",
        "--skip-git-repo-check",
        "--ignore-user-config",
        "--color",
        "never",
        "-",
      ];
  }
}

/**
 * Env vars that must not reach the child, by prefix. `CLAUDE*` and `CODEX*`
 * carry "you are running inside an agent session" state (Nota may itself have
 * been launched by one); `ANTHROPIC*` and the named keys below carry credentials
 * that would move the run onto a metered account.
 */
const DENIED_ENV_PREFIXES = ["CLAUDE", "ANTHROPIC", "CODEX"];

/**
 * The two exceptions. Both name *where the CLI's own configuration and
 * credentials live* — a user who moved them deliberately would otherwise find
 * the child unauthenticated for reasons nothing on screen explains. `CODEX_HOME`
 * survives so {@link realCodexHome} can find the login; what the child is
 * finally handed is {@link prepareCodexHome}'s jail, not this value.
 */
const ALLOWED_ENV_KEYS: ReadonlySet<string> = new Set([
  "CLAUDE_CONFIG_DIR",
  "CODEX_HOME",
]);

/** Provider credentials Nota itself resolves. None of them are the CLI's business. */
const DENIED_ENV_KEYS: ReadonlySet<string> = new Set([
  "OPENAI_API_KEY",
  "GEMINI_API_KEY",
  "DEEPSEEK_API_KEY",
  "ASSEMBLYAI_API_KEY",
  "OPENROUTER_API_KEY",
  "HUGGINGFACE_TOKEN",
]);

/** True when a variable must be withheld from a spawned CLI engine. */
export function isDeniedEnvKey(key: string): boolean {
  if (ALLOWED_ENV_KEYS.has(key)) return false;
  if (DENIED_ENV_KEYS.has(key)) return true;
  return DENIED_ENV_PREFIXES.some((prefix) => key.startsWith(prefix));
}

/**
 * The caller's environment minus everything {@link isDeniedEnvKey} refuses.
 * PATH, HOME and the rest survive untouched — the child still has to be found
 * and still has to read the user's own login.
 */
export function sanitizedEnv(
  env: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const out: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) continue;
    if (isDeniedEnvKey(key)) continue;
    out[key] = value;
  }
  return out;
}

// ── Codex home jail ──────────────────────────────────────────────────────────

/**
 * Where Codex's real configuration and login live — `$CODEX_HOME`, or `~/.codex`
 * when the owner never moved it.
 */
export function realCodexHome(env: NodeJS.ProcessEnv = process.env): string {
  const configured = env.CODEX_HOME?.trim();
  return configured ? path.resolve(configured) : path.join(homedir(), ".codex");
}

/** Nota's own `CODEX_HOME`: the login, and deliberately nothing else. */
export function notaCodexHome(): string {
  return path.join(homedir(), ".nota", "codex-home");
}

/**
 * Build the `CODEX_HOME` a summary run is given and return its path.
 *
 * `codex` has no flag that excludes `$CODEX_HOME/AGENTS.md`. `--ignore-user-config`
 * does not (measured 2026-07-28 — the OMC guide on this machine survived it, and
 * survived `-c project_doc_max_bytes=0` as well), so the only way to keep the
 * owner's personal agent guide out of a meeting summary is to hand the child a
 * different home. This one contains a single entry: `auth.json`, symlinked to
 * the real one, because the login is the only thing from that directory a
 * summary run is entitled to.
 *
 * The link is **recreated on every run**. A token refresh that writes a temp
 * file and renames it over `auth.json` replaces the symlink with a regular file,
 * which would strand the refreshed token here and leave this directory holding a
 * copy of a credential; recreating means the real file is authoritative again by
 * the next run.
 *
 * The directory is persistent (`~/.nota/codex-home`) rather than per-call: codex
 * bootstraps a model cache and some state into whatever home it is given, and
 * paying for that on every section of a sectioned summary would be absurd.
 */
export function prepareCodexHome(
  options: { env?: NodeJS.ProcessEnv; root?: string } = {},
): string {
  const env = options.env ?? process.env;
  const jail = options.root ?? notaCodexHome();
  const real = realCodexHome(env);
  mkdirSync(jail, { recursive: true });

  // The owner pointed CODEX_HOME at the jail itself: there is nothing to link
  // and nothing to exclude.
  if (path.resolve(jail) === real) return jail;

  const link = path.join(jail, "auth.json");
  rmSync(link, { force: true });
  const target = path.join(real, "auth.json");
  // No login to borrow. Leave the jail without one so the child fails with the
  // "not authenticated" error that names `codex login`, rather than silently
  // reusing whatever a previous run left behind.
  if (existsSync(target)) symlinkSync(target, link);
  return jail;
}

/**
 * The environment for one child: {@link sanitizedEnv}, plus the jailed
 * `CODEX_HOME` for codex. A failure to build the jail is fatal — running with
 * the owner's whole agent configuration loaded is the bug this exists to
 * prevent, so it may not be the fallback for it.
 */
function childEnv(
  spec: CliEngineSpec,
  base: NodeJS.ProcessEnv,
  root?: string,
): NodeJS.ProcessEnv {
  if (spec.provider !== "codex") return base;
  try {
    return { ...base, CODEX_HOME: prepareCodexHome({ env: base, root }) };
  } catch (err) {
    throw new CliEngineError(
      `Summary engine ${engineLabel(spec)}: could not prepare a private CODEX_HOME — ` +
        `${err instanceof Error ? err.message : String(err)}. Without it the summary ` +
        `would be written under your own Codex instructions. No API model was substituted.`,
      spec.provider,
    );
  }
}

// ── Timeout ──────────────────────────────────────────────────────────────────

/** Floor: CLI startup plus a model's first token, before any input length. */
export const CLI_TIMEOUT_BASE_MS = 180_000;
/** Added per 1000 prompt characters (~250 tokens). */
export const CLI_TIMEOUT_PER_KCHAR_MS = 3_000;
/** Ceiling. Past this something is wrong, not slow. */
export const CLI_TIMEOUT_MAX_MS = 1_800_000;

/**
 * How long to wait for one call, scaled to the prompt. These engines are minutes
 * slow by design — a generous budget is the point of using them — so the number
 * is deliberately large and the error says exactly how long it was.
 */
export function cliTimeoutMs(promptChars: number): number {
  const scaled =
    CLI_TIMEOUT_BASE_MS +
    Math.ceil(promptChars / 1000) * CLI_TIMEOUT_PER_KCHAR_MS;
  return Math.min(CLI_TIMEOUT_MAX_MS, scaled);
}

/** `930000` → `"15m30s"`. Used only in messages. */
export function formatWait(ms: number): string {
  const totalSeconds = Math.round(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return minutes > 0 ? `${minutes}m${seconds}s` : `${seconds}s`;
}

// ── Output ───────────────────────────────────────────────────────────────────

/**
 * CSI escape sequences, anchored on the ESC byte — which is the whole point:
 * the bracket-and-terminator half of this pattern on its own also describes
 * `- [ ] Action item`, so an unanchored version would quietly eat every
 * checkbox in the summary it was meant to be tidying.
 */
// eslint-disable-next-line no-control-regex
const ANSI = /\u001B\[[0-9;?]*[ -/]*[@-~]/g;

/**
 * Tidy a CLI's stdout into the plain text the HTTP path would have returned.
 *
 * Conservative on purpose: strip ANSI (a CLI that ignored `--color never` on a
 * pipe), unwrap a fence that encloses the *whole* answer (models hand back
 * ```markdown blocks unasked), and trim. Nothing else is removed — both engines
 * are invoked in modes where stdout carries the final message alone, so a
 * heuristic that deleted "noise" would eventually delete a summary line.
 */
export function cleanCliOutput(raw: string): string {
  const text = raw.replace(ANSI, "").trim();
  const fenced = text.match(/^```[A-Za-z0-9_-]*\n([\s\S]*?)\n?```$/);
  return (fenced ? fenced[1] : text).trim();
}

/**
 * True when a CLI's own output says the problem is a missing or expired login.
 * Matched against stderr *and* stdout because the two CLIs disagree about where
 * they complain.
 */
export function looksUnauthenticated(text: string): boolean {
  return /not (?:logged in|authenticated)|please (?:run )?.{0,20}login|\blogin required\b|unauthorized|401|invalid api key|no credentials|authentication (?:failed|error)|session expired|expired token/i.test(
    text,
  );
}

/**
 * How much exit-0 output may still be sniffed for an auth complaint.
 *
 * The sniff has to be bounded because {@link looksUnauthenticated} matches
 * `401` and `unauthorized`, and a *meeting* is allowed to have been about an
 * HTTP status. Nothing this short is a summary: the prompt asks for a title, a
 * narrative, key topics, decisions, action items and tags, and the shortest
 * real answer any of these engines has produced is several times this. So an
 * output under the bound that also reads as an auth complaint is exactly that,
 * not a summary that happens to mention one.
 */
export const CLI_AUTH_SNIFF_MAX_CHARS = 400;

/**
 * True when a CLI's exit-0 output is an auth complaint standing in for an
 * answer. Both CLIs can report an expired login on the happy exit path, printing
 * one line where a summary should be — and one line parsed as a summary is
 * written over the user's notes.
 */
export function isAuthComplaint(content: string, stderr = ""): boolean {
  if (content.length > CLI_AUTH_SNIFF_MAX_CHARS) return false;
  return looksUnauthenticated(`${stderr}\n${content}`);
}

/** Keep error messages readable when a CLI dumps a stack trace. */
function tail(text: string, maxChars = 600): string {
  const trimmed = text.trim();
  if (trimmed.length <= maxChars) return trimmed;
  return `…${trimmed.slice(-maxChars)}`;
}

// ── Running ──────────────────────────────────────────────────────────────────

/** Injection seam so tests drive the engine without a real binary. */
export type SpawnFn = typeof spawn;

export interface RunCliOptions {
  /** Overrides {@link cliTimeoutMs}. */
  timeoutMs?: number;
  spawnFn?: SpawnFn;
  /** Overrides the scratch working directory. */
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /** Overrides {@link notaCodexHome} — the jailed `CODEX_HOME`. Tests only. */
  codexHomeRoot?: string;
}

function notFoundError(spec: CliEngineSpec): CliEngineError {
  const binary = CLI_BINARY[spec.provider];
  return new CliEngineError(
    `Summary engine ${engineLabel(spec)}: ${binary} not found on PATH — ` +
      `install ${CLI_PRODUCT[spec.provider]} or choose an API model ` +
      `(e.g. -m gpt-5-mini). No API model was substituted.`,
    spec.provider,
  );
}

/**
 * Run one prompt through a CLI engine and return its plain-text answer.
 *
 * Rejects with {@link CliEngineError} on every failure mode; never resolves with
 * a partial or empty answer, because the caller parses the result into a summary
 * and a blank one would be written over the user's notes.
 */
export function runCliPrompt(
  spec: CliEngineSpec,
  prompt: string,
  options: RunCliOptions = {},
): Promise<string> {
  const binary = CLI_BINARY[spec.provider];
  const timeoutMs = options.timeoutMs ?? cliTimeoutMs(prompt.length);
  const spawnFn = options.spawnFn ?? spawn;

  return new Promise<string>((resolve, reject) => {
    let env: NodeJS.ProcessEnv;
    try {
      env = childEnv(spec, options.env ?? sanitizedEnv(), options.codexHomeRoot);
    } catch (err) {
      reject(err);
      return;
    }

    let child: ChildProcess;
    try {
      child = spawnFn(binary, cliArgs(spec), {
        // A scratch cwd: no project-level CLAUDE.md / AGENTS.md discovery, and
        // nothing for a misbehaving agent to be near. The *user*-level guides
        // are excluded by `--safe-mode` and by the jailed CODEX_HOME above —
        // cwd alone never reached them.
        cwd: options.cwd ?? tmpdir(),
        env,
        // Never `inherit`: the child must not get Nota's terminal, and a CLI
        // that finds a TTY on stdin waits for a human who is not there.
        stdio: ["pipe", "pipe", "pipe"],
      });
    } catch (err) {
      reject(
        (err as NodeJS.ErrnoException)?.code === "ENOENT"
          ? notFoundError(spec)
          : new CliEngineError(
              `Summary engine ${engineLabel(spec)}: could not start ${binary} — ` +
                `${err instanceof Error ? err.message : String(err)}`,
              spec.provider,
            ),
      );
      return;
    }

    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;

    const finish = (fn: () => void): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };

    const timer = setTimeout(() => {
      timedOut = true;
      // SIGTERM first so the CLI can clean up; SIGKILL if it will not go.
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 5_000).unref?.();
      finish(() =>
        reject(
          new CliEngineError(
            `Summary engine ${engineLabel(spec)}: ${binary} did not finish within ` +
              `${formatWait(timeoutMs)} (waited ${formatWait(timeoutMs)}) and was ` +
              `stopped. Re-run, or choose an API model. No API model was substituted.` +
              (stderr.trim() ? ` Last output: ${tail(stderr, 200)}` : ""),
            spec.provider,
          ),
        ),
      );
    }, timeoutMs);

    child.stdout?.setEncoding("utf-8");
    child.stdout?.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr?.setEncoding("utf-8");
    child.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });

    child.on("error", (err: NodeJS.ErrnoException) => {
      finish(() =>
        reject(
          err.code === "ENOENT"
            ? notFoundError(spec)
            : new CliEngineError(
                `Summary engine ${engineLabel(spec)}: ${binary} failed to run — ${err.message}`,
                spec.provider,
              ),
        ),
      );
    });

    child.on("close", (code: number | null) => {
      if (timedOut) return;
      finish(() => {
        if (code !== 0) {
          if (looksUnauthenticated(`${stderr}\n${stdout}`)) {
            reject(
              new CliEngineError(
                `Summary engine ${engineLabel(spec)}: ${binary} is not authenticated — ` +
                  `${CLI_LOGIN_HINT[spec.provider]}, then re-run. ` +
                  `No API model was substituted.` +
                  (stderr.trim() ? ` ${binary} said: ${tail(stderr)}` : ""),
                spec.provider,
              ),
            );
            return;
          }
          reject(
            new CliEngineError(
              `Summary engine ${engineLabel(spec)}: ${binary} exited with code ${code}. ` +
                `No API model was substituted.` +
                (stderr.trim() ? ` ${binary} said: ${tail(stderr)}` : ""),
              spec.provider,
            ),
          );
          return;
        }

        // Exit 0 is not on its own a success. Both CLIs report an expired login
        // on the happy exit path — sometimes with nothing on stdout, sometimes
        // with the complaint itself where the summary should be — and either
        // one, taken as an answer, is parsed into a summary and written over the
        // user's notes.
        const content = cleanCliOutput(stdout);
        if (!content || isAuthComplaint(content, stderr)) {
          if (looksUnauthenticated(`${stderr}\n${content}`)) {
            const said = tail(stderr.trim() ? stderr : content);
            reject(
              new CliEngineError(
                `Summary engine ${engineLabel(spec)}: ${binary} is not authenticated — ` +
                  `${CLI_LOGIN_HINT[spec.provider]}, then re-run. ` +
                  `No API model was substituted. ${binary} said: ${said}`,
                spec.provider,
              ),
            );
            return;
          }
          reject(
            new CliEngineError(
              `Summary engine ${engineLabel(spec)}: ${binary} exited cleanly but produced ` +
                `no output. No API model was substituted.` +
                (stderr.trim() ? ` ${binary} said: ${tail(stderr)}` : ""),
              spec.provider,
            ),
          );
          return;
        }
        resolve(content);
      });
    });

    child.stdin?.on("error", () => {
      // A CLI that exits before reading the whole prompt gives us EPIPE. The
      // close handler already owns that story; swallowing here only stops an
      // unhandled 'error' from taking the process down.
    });
    child.stdin?.end(prompt);
  });
}

// ── Diagnostics ──────────────────────────────────────────────────────────────

export interface CliProbe {
  provider: CliProvider;
  binary: string;
  /** Absolute path, when the binary was found on PATH. */
  path?: string;
  /** First line of `<binary> --version`, when it answered. */
  version?: string;
  /** One-line human summary for `nota config` / preflight. */
  detail: string;
  found: boolean;
}

/**
 * First executable named `binary` on PATH, or `undefined`. Resolved here rather
 * than by shelling out to `which`, so "not installed" costs no process at all —
 * which is what keeps `nota config` and preflight from spawning anything on a
 * machine that has neither CLI.
 */
export function resolveBinaryPath(
  binary: string,
  env: NodeJS.ProcessEnv = process.env,
): string | undefined {
  const raw = env.PATH ?? "";
  for (const dir of raw.split(path.delimiter)) {
    if (!dir) continue;
    const candidate = path.join(dir, binary);
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Not here, or not executable.
    }
  }
  return undefined;
}

/** How long a `--version` probe may take before we call it unhealthy. */
const PROBE_TIMEOUT_MS = 10_000;

/**
 * The version a `--version` probe reported: the first non-blank line of
 * **stdout**, falling back to stderr only when stdout said nothing at all.
 *
 * The two streams are kept apart on purpose. Interleaving them into one buffer
 * and taking its first line makes the answer whatever arrived first, and startup
 * noise on stderr is the thing that arrives first — a Node deprecation warning
 * from an exported `NODE_OPTIONS` (which {@link sanitizedEnv} deliberately does
 * not strip) would be printed by `nota config` as the CLI's version. Neither CLI
 * writes its version to stderr, so the fallback is only ever a last resort for a
 * wrapper script that does.
 */
export function firstVersionLine(stdout: string, stderr = ""): string | undefined {
  const firstLine = (text: string): string | undefined =>
    text
      .split("\n")
      .map((line) => line.trim())
      .find((line) => line.length > 0);
  return firstLine(stdout) ?? firstLine(stderr);
}

/**
 * Cheap health check for one engine: is the binary on PATH, and does it answer
 * `--version`?
 *
 * Deliberately **not** a summary call. Preflight exists to be cheaper than the
 * transcription it guards, and a real CLI completion costs minutes of wall time
 * on every run. The consequence is stated rather than hidden: presence and
 * version are verified here, a stale login is not, and an unauthenticated engine
 * fails at the summary step with an error naming the login.
 */
export function probeCliEngine(
  provider: CliProvider,
  options: { spawnFn?: SpawnFn; env?: NodeJS.ProcessEnv } = {},
): Promise<CliProbe> {
  const binary = CLI_BINARY[provider];
  const env = options.env ?? sanitizedEnv();
  const resolved = resolveBinaryPath(binary, env);
  const base = { provider, binary, found: false as boolean };

  if (!resolved) {
    return Promise.resolve({
      ...base,
      found: false,
      detail: `${binary} not found on PATH — install ${CLI_PRODUCT[provider]}`,
    });
  }

  const spawnFn = options.spawnFn ?? spawn;
  return new Promise<CliProbe>((resolve) => {
    let child: ChildProcess;
    try {
      child = spawnFn(resolved, ["--version"], {
        cwd: tmpdir(),
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (err) {
      resolve({
        ...base,
        path: resolved,
        detail: `${binary} found at ${resolved} but would not run: ${
          err instanceof Error ? err.message : String(err)
        }`,
      });
      return;
    }

    let stdout = "";
    let stderr = "";
    let settled = false;
    const done = (probe: CliProbe): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(probe);
    };

    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      done({
        ...base,
        path: resolved,
        detail: `${binary} at ${resolved} did not answer --version within ${formatWait(
          PROBE_TIMEOUT_MS,
        )}`,
      });
    }, PROBE_TIMEOUT_MS);

    child.stdout?.setEncoding("utf-8");
    child.stdout?.on("data", (chunk: string) => {
      stdout += chunk;
    });
    child.stderr?.setEncoding("utf-8");
    child.stderr?.on("data", (chunk: string) => {
      stderr += chunk;
    });
    child.on("error", (err: Error) => {
      done({
        ...base,
        path: resolved,
        detail: `${binary} at ${resolved} would not run: ${err.message}`,
      });
    });
    child.on("close", (code: number | null) => {
      const version = firstVersionLine(stdout, stderr);
      if (code === 0 && version) {
        done({
          ...base,
          found: true,
          path: resolved,
          version,
          detail: `${version} at ${resolved}`,
        });
        return;
      }
      done({
        ...base,
        path: resolved,
        detail:
          `${binary} at ${resolved} exited ${code} for --version` +
          (stderr.trim() ? ` — ${tail(stderr, 200)}` : ""),
      });
    });
  });
}
