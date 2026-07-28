/**
 * Preflight: a fast, mostly-free "can this run succeed end to end?" gate that
 * runs before any paid transcription. It exercises the real request builders so
 * a config-shape bug (e.g. a deprecated model parameter) surfaces here for ~free
 * instead of after money is spent. Consumed two ways:
 *
 *  - `nota preflight [--json]` (see src/cli/preflight.ts) — the macOS home
 *    renders the JSON as a traffic-light health list.
 *  - an inline backstop in the pipeline (orchestrator) so a direct CLI run is
 *    never ungated.
 *
 * Each check reports one of four statuses, and each status maps to a fixed
 * consequence so the UI never has to re-derive severity:
 *
 *   ok         green   verified working
 *   fail       red     will fail deterministically (missing tool/key, 4xx canary)
 *   unverified yellow  couldn't verify (offline / timeout / 5xx) — proceed at risk
 *   optional   grey    not required; never blocks
 *
 * `overall` folds the checks: any blocking `fail` → blocked; else any
 * `unverified` → unverified; else ready.
 */

import { AssemblyAI } from "assemblyai";
import OpenAI from "openai";
import type { AppConfig } from "../config.js";
import { checkFfmpeg } from "../utils/ffmpeg.js";
import { getModel } from "../registry.js";
import { canaryAssemblyAI } from "./assemblyai.js";
import { probeCliEngine, type CliEngineSpec } from "./cli-engine.js";
import { canarySummaryModel } from "./summarize.js";
import { isIdentityAvailable } from "./embed.js";
import { checkPython, checkHuggingFaceToken } from "./validate.js";

export type CheckStatus = "ok" | "fail" | "unverified" | "optional";
export type Overall = "ready" | "blocked" | "unverified";

export interface PreflightCheck {
  /** Stable id (also the fix-route key for the app). */
  id: string;
  label: string;
  status: CheckStatus;
  /** One-line human detail (masked; never a secret). */
  detail: string;
  /** When true, a `fail` here blocks recording. `optional` is never blocking. */
  blocking: boolean;
  /** HTTP status when the failure was an API rejection, for diagnostics. */
  httpStatus?: number;
}

export interface PreflightResult {
  overall: Overall;
  checks: PreflightCheck[];
  /** ISO timestamp; also the cache key for freshness. */
  checkedAt: string;
}

const NETWORK_CODES = new Set([
  "ENOTFOUND",
  "ECONNREFUSED",
  "ECONNRESET",
  "ETIMEDOUT",
  "EAI_AGAIN",
  "EPIPE",
]);

interface Classified {
  kind: "deterministic" | "network";
  httpStatus?: number;
  message: string;
}

/**
 * Decide whether an error is a deterministic rejection (a bad key or bad request
 * that will fail identically every run → red) or a transient/reachability
 * failure (offline, timeout, 5xx → yellow). The distinction is what separates
 * "block the run to save money" from "we couldn't check; you decide".
 */
export function classifyError(err: unknown): Classified {
  const message = err instanceof Error ? err.message : String(err);

  // OpenAI SDK attaches a numeric HTTP status; AssemblyAI throws a bare Error.
  const status = (err as { status?: unknown })?.status;
  if (typeof status === "number") {
    if (status >= 500) return { kind: "network", httpStatus: status, message };
    return { kind: "deterministic", httpStatus: status, message };
  }

  // Network / reachability signals → unverified.
  const causeCode = (err as { cause?: { code?: unknown } })?.cause?.code;
  const name = (err as { name?: unknown })?.name;
  if (
    (typeof causeCode === "string" && NETWORK_CODES.has(causeCode)) ||
    name === "APIConnectionError" ||
    name === "APIConnectionTimeoutError" ||
    /fetch failed|network|timeout|ENOTFOUND|ECONN|EAI_AGAIN|socket hang up/i.test(
      message,
    )
  ) {
    return { kind: "network", message };
  }

  // Anything else (e.g. an AssemblyAI auth-error string) is treated as a
  // deterministic failure — it will not fix itself on retry.
  return { kind: "deterministic", message };
}

export function overallOf(checks: PreflightCheck[]): Overall {
  if (checks.some((c) => c.blocking && c.status === "fail")) return "blocked";
  if (checks.some((c) => c.status === "unverified")) return "unverified";
  return "ready";
}

async function checkAudioTools(): Promise<PreflightCheck> {
  const base = { id: "audio-tools", label: "Audio tools", blocking: true };
  try {
    await checkFfmpeg();
    return { ...base, status: "ok", detail: "ffmpeg and ffprobe found on PATH" };
  } catch (err) {
    return {
      ...base,
      status: "fail",
      detail: err instanceof Error ? err.message : "ffmpeg not found",
    };
  }
}

async function checkTranscription(config: AppConfig): Promise<PreflightCheck> {
  const entry = getModel(config.transcriptionModel);
  const label = `Transcription — ${entry?.label ?? config.transcriptionModel}`;
  const base = { id: "transcription", label, blocking: true };
  if (!config.transcriptionApiKey) {
    return {
      ...base,
      status: "fail",
      detail: `${entry?.apiKeyEnv ?? "API key"} not set (env or ~/.nota/config)`,
    };
  }
  try {
    if (config.provider === "assemblyai") {
      await canaryAssemblyAI(config.transcriptionApiKey);
    } else {
      // Whisper path is an OpenAI transcription model; a free models.list()
      // confirms the key + reachability without transcribing.
      await new OpenAI({
        apiKey: config.transcriptionApiKey,
        maxRetries: 0,
      }).models.list();
    }
    return { ...base, status: "ok", detail: "API key verified — no charge" };
  } catch (err) {
    const c = classifyError(err);
    return c.kind === "network"
      ? { ...base, status: "unverified", detail: `Couldn't reach service: ${c.message}` }
      : {
          ...base,
          status: "fail",
          detail: c.message,
          ...(c.httpStatus ? { httpStatus: c.httpStatus } : {}),
        };
  }
}

/**
 * Preflight for a `cli`-execution summary model: is the binary on PATH, and
 * does it answer `--version`?
 *
 * Deliberately **not** a canary completion. The HTTP canary is a one-token
 * request that costs a fraction of a cent; a CLI completion costs minutes of
 * wall time, on every single run, for a gate whose whole purpose is to be
 * cheaper than the transcription it guards. So presence is verified and a stale
 * login is not — the detail line says which, and an unauthenticated engine
 * fails at the summary step with an error naming the login.
 */
async function checkCliSummary(
  base: { id: string; label: string; blocking: boolean },
  cli: CliEngineSpec,
): Promise<PreflightCheck> {
  const probe = await probeCliEngine(cli.provider);
  if (!probe.found) {
    return { ...base, status: "fail", detail: probe.detail };
  }
  return {
    ...base,
    status: "ok",
    detail: `${probe.detail} — presence verified; login is not probed`,
  };
}

async function checkSummary(config: AppConfig): Promise<PreflightCheck> {
  const entry = getModel(config.summaryModel);
  const label = `Summary — ${entry?.label ?? config.summaryModel}`;
  const base = { id: "summary", label, blocking: true };
  if (config.summaryCliEngine) {
    return checkCliSummary(base, config.summaryCliEngine);
  }
  if (!config.summaryApiKey) {
    return {
      ...base,
      status: "fail",
      detail: `${entry?.apiKeyEnv ?? "API key"} not set (env or ~/.nota/config)`,
    };
  }
  try {
    // The canary is a real request, so it carries the *wire* id: OpenRouter is
    // asked for `anthropic/claude-sonnet-5`, never `openrouter/…`. Sending the
    // canonical id here would 400 on an unknown slug and block every run behind
    // a gate whose whole job is to be cheaper than the transcription it guards.
    await canarySummaryModel(
      config.summaryApiKey,
      config.summaryWireModel,
      config.summaryBaseURL,
    );
    return { ...base, status: "ok", detail: "Request shape and key verified" };
  } catch (err) {
    const c = classifyError(err);
    return c.kind === "network"
      ? { ...base, status: "unverified", detail: `Couldn't reach service: ${c.message}` }
      : {
          ...base,
          status: "fail",
          detail: c.message,
          ...(c.httpStatus ? { httpStatus: c.httpStatus } : {}),
        };
  }
}

async function checkIdentity(config: AppConfig): Promise<PreflightCheck> {
  // Identity is always optional: it soft-fails to generic labels and never
  // blocks a run, so it can only be green (available) or grey (off/unavailable).
  const base = { id: "identity", label: "Speaker identity", blocking: false };
  let available = false;
  try {
    available = await isIdentityAvailable();
  } catch {
    available = false;
  }
  if (available) {
    return {
      ...base,
      status: config.identify ? "ok" : "optional",
      detail: config.identify
        ? "On — ONNX voice model ready"
        : "Available — enable with --identify",
    };
  }
  return {
    ...base,
    status: "optional",
    detail: "Optional — voice model not downloaded",
  };
}

function checkDiarization(config: AppConfig): Promise<PreflightCheck> {
  const base = { id: "diarization", label: "Speaker diarization (pyannote)", blocking: true };
  return (async () => {
    try {
      await checkPython();
      checkHuggingFaceToken();
      return { ...base, status: "ok" as const, detail: "Python, pyannote, and token present" };
    } catch (err) {
      return {
        ...base,
        status: "fail" as const,
        detail: err instanceof Error ? err.message : "diarization prerequisites missing",
      };
    }
  })();
}

/**
 * Run every relevant check concurrently and fold the result. Only checks that
 * apply to the resolved config are included (e.g. diarization prerequisites only
 * on the whisper branch with diarize enabled), so the app renders exactly the
 * rows that matter for this run.
 */
export async function runPreflight(
  config: AppConfig,
  now: string = new Date().toISOString(),
): Promise<PreflightResult> {
  const jobs: Promise<PreflightCheck>[] = [
    checkAudioTools(),
    checkTranscription(config),
    checkSummary(config),
    checkIdentity(config),
  ];
  if (config.provider === "whisper" && config.diarize) {
    jobs.push(checkDiarization(config));
  }
  const checks = await Promise.all(jobs);
  return { overall: overallOf(checks), checks, checkedAt: now };
}
