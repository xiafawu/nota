import { applyEnvFile } from "./utils/env-file.js";
import {
  DEFAULT_SUMMARY_MODEL,
  DEFAULT_TRANSCRIPTION_MODEL,
  requireModel,
  type ModelEntry,
} from "./registry.js";
import { loadSettings, type NotaSettings } from "./utils/settings.js";

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
  numSpeakers?: number;
  identify: boolean;
  history: boolean;
  /** Reprocess even when an identical audio file is already in history. */
  force: boolean;
  /** Skip the inline preflight gate before transcription. */
  skipPreflight: boolean;
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
 * Resolve effective settings and API keys.
 *
 * Precedence for each model: CLI flag > settings.json > built-in default.
 * `--provider` is a back-compat alias: it seeds the transcription default
 * (`whisper` → `whisper-1`, `assemblyai` → `universal`) but yields to an
 * explicit `--transcribe-model` flag or a `transcription.model` setting.
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

  // Summary model.
  const summaryId =
    options.model ?? settings.summary?.model ?? DEFAULT_SUMMARY_MODEL;
  const summaryEntry = requireModel(summaryId, "summary");

  // Pipeline branch derives from the transcription provider.
  const provider: Provider =
    transcriptionEntry.provider === "assemblyai" ? "assemblyai" : "whisper";

  // Require only the keys the resolved models need. Preflight passes
  // `requireKeys: false` so it can *report* a missing key as a failed check
  // instead of throwing before any check runs; the key is then an empty string
  // and the relevant check surfaces it.
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
    numSpeakers: options.numSpeakers,
    identify: options.identify ?? false,
    history: options.history ?? true,
    force: options.force ?? false,
    skipPreflight: options.skipPreflight ?? false,
  };
}
