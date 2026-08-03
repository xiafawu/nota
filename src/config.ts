import { applyEnvFile } from "./utils/env-file.js";
import {
  DEFAULT_TRANSCRIPTION_MODEL,
  requireModel,
  requiresApiKey,
  type ModelEntry,
} from "./registry.js";
import { cliEngineFor, type CliEngineSpec } from "./pipeline/cli-engine.js";
import { loadSettings, type NotaSettings } from "./utils/settings.js";
import { effectiveCatalog } from "./catalog.js";

/**
 * Which pipeline branch runs. Derived from the resolved transcription model's
 * provider (assemblyai models → assemblyai pipeline; openai transcription
 * models → whisper pipeline). Not a user-facing provider selector — `--provider`
 * survives only as a back-compat alias that seeds the transcription model.
 */
export type Provider = "assemblyai" | "whisper";

export interface CLIOptions {
  output?: string;
  language?: string;
  /** Summary model (`-m/--model`). */
  model?: string;
  /** Transcription model (`--transcribe-model`). */
  transcribeModel?: string;
  verbose?: boolean;
  diarize?: boolean;
  provider?: string;
  numSpeakers?: number;
  identify?: boolean;
  history?: boolean;
  force?: boolean;
  skipPreflight?: boolean;
  summary?: boolean;
  verifySpeakers?: boolean;
  /** Record kind for this run ("meeting" | "file" | "memo"). Default: file. */
  kind?: "meeting" | "file" | "memo";
}

export interface AppConfig {
  provider: Provider;
  transcriptionModel: string;
  /** Canonical summary model id — what is persisted and reported. */
  summaryModel: string;
  /**
   * The same model as the summary provider's own API names it: the canonical id
   * with its provider namespace stripped. OpenRouter is asked for
   * `anthropic/claude-sonnet-5`, not `openrouter/anthropic/claude-sonnet-5`.
   * Never persisted — history and usage records keep the canonical id.
   */
  summaryWireModel: string;
  /** API key for the transcription model's provider. */
  transcriptionApiKey: string;
  /** API key for the summary model's provider. */
  summaryApiKey: string;
  /** OpenAI-compatible base URL for the summary model (set for gemini). */
  summaryBaseURL?: string;
  /**
   * Present when the resolved summary model is a local subprocess engine
   * (ADR 0003). Its presence — not the model id — is what routes the summary
   * call away from the HTTP client, and it is also why `summaryApiKey` is empty
   * for these runs without that being a misconfiguration.
   */
  summaryCliEngine?: CliEngineSpec;
  language?: string;
  verbose: boolean;
  diarize: boolean;
  summary: boolean;
  numSpeakers?: number;
  identify: boolean;
  history: boolean;
  /** Reprocess even when an identical audio file is already in history. */
  force: boolean;
  skipPreflight: boolean;
  verifySpeakers: boolean;
  /**
   * What this run's history record represents. Defaults to "file" — the CLI
   * always processes audio files; "meeting" and "memo" records are written by
   * the macOS app's live-session persistence.
   */
  kind: "meeting" | "file" | "memo";
}

function parseProviderAlias(provider?: string): Provider {
  if (!provider || provider === "assemblyai") return "assemblyai";
  if (provider === "whisper") return "whisper";
  throw new Error(
    `Unsupported provider: ${provider}. Supported providers: assemblyai, whisper`,
  );
}

function requireKey(entry: ModelEntry): string {
  const value = process.env[entry.apiKeyEnv];
  if (!value) {
    throw new Error(
      `${entry.apiKeyEnv} environment variable is required for model ${entry.id}.`,
    );
  }
  return value;
}

/**
 * Key-aware default chain for the summary model:
 * 1. deepseek-v4-flash if DEEPSEEK_API_KEY resolves
 * 2. gpt-5.4-mini if OPENAI_API_KEY resolves
 * 3. gemini-3.6-flash if GEMINI_API_KEY resolves
 * 4. Error listing the three options
 *
 * Each chain entry is verified against the effective catalog; if a chain id is
 * absent from the catalog, it falls to the next.
 *
 * No CLI engine is in the chain and none may be added to it (ADR 0003). "Free
 * but slow" must never win a default: a summary that takes minutes of local
 * wall time is a choice the owner makes explicitly with `-m` or
 * `nota settings set summary.model`, and the error below lists API models only
 * for the same reason — offering a subprocess as the rescue for a missing key
 * would make it the effective default on any machine without one.
 */
function resolveDefaultSummaryId(): string {
  const { catalog } = effectiveCatalog();
  const catalogIds = new Set(catalog.models.map((m) => m.id));

  const chain: Array<{ id: string; env: string; hint?: string }> = [
    { id: "deepseek-v4-flash", env: "DEEPSEEK_API_KEY", hint: " (cheaper default — set DEEPSEEK_API_KEY)" },
    { id: "gpt-5.4-mini", env: "OPENAI_API_KEY" },
    { id: "gemini-3.6-flash", env: "GEMINI_API_KEY" },
  ];

  let suggestedDeepseek = false;
  for (const link of chain) {
    if (!catalogIds.has(link.id)) continue;
    if (process.env[link.env]) {
      return link.id;
    }
    if (link.hint && !suggestedDeepseek) {
      suggestedDeepseek = true;
    }
  }

  // None of the chain models are available via key — give a descriptive error
  const options = chain
    .filter((l) => catalogIds.has(l.id))
    .map((l) => `${l.id} (needs ${l.env})`)
    .join(", ");
  throw new Error(
    `No summary model available. Set one of: ${options}`,
  );
}

/**
 * Warn on stderr once per run when a configured summary model is absent from
 * the effective catalog, and return the resolved default.
 */
function zombieFallback(
  configuredId: string,
): { id: string; warned: boolean } {
  const { catalog } = effectiveCatalog();
  const found = catalog.models.some((m) => m.id === configuredId);
  if (!found) {
    const resolved = resolveDefaultSummaryId();
    process.stderr.write(
      `warning: model "${configuredId}" is no longer available; using ${resolved}\n`,
    );
    return { id: resolved, warned: true };
  }
  return { id: configuredId, warned: false };
}

/**
 * Resolve effective settings and API keys.
 *
 * Precedence for each model: CLI flag > settings.json > built-in default.
 * `--provider` is a back-compat alias: it seeds the transcription default
 * (`whisper` → `whisper-1`, `assemblyai` → `universal`) but yields to an
 * explicit `--transcribe-model` flag or a `transcription.model` setting.
 *
 * Summary model now uses a key-aware default chain:
 * deepseek-v4-flash > gpt-5.4-mini > gemini-3.6-flash.
 *
 * Only the API keys the resolved models actually need are required.
 *
 * `settings` may be injected (tests); otherwise it is loaded from disk.
 */
export function loadConfig(
  options: CLIOptions,
  settings: NotaSettings = loadSettings(),
  { requireKeys = true }: { requireKeys?: boolean } = {},
): AppConfig {
  // Fill unset API keys from ~/.nota/config before reading them (env wins).
  applyEnvFile();

  if (
    options.numSpeakers !== undefined &&
    (!Number.isInteger(options.numSpeakers) || options.numSpeakers < 1)
  ) {
    throw new Error("--num-speakers must be a positive integer");
  }

  // Transcription model: explicit flag/setting wins over the --provider alias.
  const explicitTranscription =
    options.transcribeModel ?? settings.transcription?.model;
  let transcriptionId: string;
  if (explicitTranscription) {
    transcriptionId = explicitTranscription;
  } else {
    const alias = parseProviderAlias(options.provider);
    transcriptionId =
      alias === "whisper" ? "whisper-1" : DEFAULT_TRANSCRIPTION_MODEL;
  }
  // A bare `--provider whisper` with no transcription override is still valid,
  // but `parseProviderAlias` also guards against unsupported provider strings.
  if (explicitTranscription) parseProviderAlias(options.provider);

  const transcriptionEntry = requireModel(transcriptionId, "transcription");

  // Summary model: CLI flag > settings > key-aware chain.
  // If the resolved id is a zombie (absent from catalog), warn and fall back.
  let summaryId = options.model ?? settings.summary?.model;
  if (summaryId) {
    const fallback = zombieFallback(summaryId);
    summaryId = fallback.id;
  } else {
    summaryId = resolveDefaultSummaryId();
  }
  const summaryEntry = requireModel(summaryId, "summary");

  // Pipeline branch derives from the transcription provider.
  const provider: Provider =
    transcriptionEntry.provider === "assemblyai" ? "assemblyai" : "whisper";

  // Require only the keys the resolved models need. A `cli` engine needs none:
  // its preconditions are a binary on PATH and the CLI's own login (ADR 0003),
  // and demanding a key here would refuse a run that would have worked. Decided
  // on the execution kind, never on the id.
  const readKey = (entry: ModelEntry): string => {
    if (!requiresApiKey(entry)) return "";
    return requireKeys ? requireKey(entry) : (process.env[entry.apiKeyEnv] ?? "");
  };
  const transcriptionApiKey = readKey(transcriptionEntry);
  const summaryApiKey = readKey(summaryEntry);

  return {
    provider,
    transcriptionModel: transcriptionEntry.id,
    summaryModel: summaryEntry.id,
    summaryWireModel: summaryEntry.wireId,
    transcriptionApiKey,
    summaryApiKey,
    summaryBaseURL: summaryEntry.baseURL,
    summaryCliEngine: cliEngineFor(summaryEntry),
    language: options.language,
    verbose: options.verbose ?? false,
    diarize: provider === "assemblyai" ? true : (options.diarize ?? true),
    summary: options.summary ?? true,
    numSpeakers: options.numSpeakers,
    identify: options.identify ?? false,
    verifySpeakers: options.verifySpeakers ?? true,
    force: options.force ?? false,
    history: options.history ?? true,
    skipPreflight: options.skipPreflight ?? false,
    kind: options.kind ?? "file",
  };
}
