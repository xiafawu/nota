import { applyEnvFile } from "./utils/env-file.js";
import {
  DEFAULT_TRANSCRIPTION_MODEL,
  requireModel,
  type ModelEntry,
} from "./registry.js";
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
}

export interface AppConfig {
  provider: Provider;
  transcriptionModel: string;
  summaryModel: string;
  /** API key for the transcription model's provider. */
  transcriptionApiKey: string;
  /** API key for the summary model's provider. */
  summaryApiKey: string;
  /** OpenAI-compatible base URL for the summary model (set for gemini). */
  summaryBaseURL?: string;
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

  // Require only the keys the resolved models need.
  const readKey = (entry: ModelEntry): string =>
    requireKeys ? requireKey(entry) : (process.env[entry.apiKeyEnv] ?? "");
  const transcriptionApiKey = readKey(transcriptionEntry);
  const summaryApiKey = readKey(summaryEntry);

  return {
    provider,
    transcriptionModel: transcriptionEntry.id,
    summaryModel: summaryEntry.id,
    transcriptionApiKey,
    summaryApiKey,
    summaryBaseURL: summaryEntry.baseURL,
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
  };
}
