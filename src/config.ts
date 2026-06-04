export type Provider = "assemblyai" | "whisper";

export interface CLIOptions {
  output?: string;
  language?: string;
  model?: string;
  verbose?: boolean;
  diarize?: boolean;
  provider?: string;
  numSpeakers?: number;
  identify?: boolean;
  history?: boolean;
}

export interface AppConfig {
  provider: Provider;
  openaiApiKey: string;
  assemblyaiApiKey?: string;
  summaryModel: string;
  language?: string;
  verbose: boolean;
  diarize: boolean;
  numSpeakers?: number;
  identify: boolean;
  history: boolean;
  /** Picovoice AccessKey for on-device Eagle speaker recognition (identity). */
  picovoiceAccessKey?: string;
}

function parseProvider(provider?: string): Provider {
  if (!provider || provider === "assemblyai") return "assemblyai";
  if (provider === "whisper") return "whisper";
  throw new Error(
    `Unsupported provider: ${provider}. Supported providers: assemblyai, whisper`,
  );
}

export function loadConfig(options: CLIOptions): AppConfig {
  const openaiApiKey = process.env.OPENAI_API_KEY;
  if (!openaiApiKey) {
    throw new Error(
      "OPENAI_API_KEY environment variable is required. Get one at https://platform.openai.com/api-keys",
    );
  }

  const provider = parseProvider(options.provider);

  if (
    options.numSpeakers !== undefined &&
    (!Number.isInteger(options.numSpeakers) || options.numSpeakers < 1)
  ) {
    throw new Error("--num-speakers must be a positive integer");
  }

  const assemblyaiApiKey = process.env.ASSEMBLYAI_API_KEY;
  if (provider === "assemblyai" && !assemblyaiApiKey) {
    throw new Error(
      "ASSEMBLYAI_API_KEY environment variable is required when using assemblyai provider. " +
        "Get one at https://www.assemblyai.com/dashboard/signup",
    );
  }

  return {
    provider,
    openaiApiKey,
    assemblyaiApiKey,
    summaryModel: options.model ?? "gpt-4o",
    language: options.language,
    verbose: options.verbose ?? false,
    diarize: provider === "assemblyai" ? true : (options.diarize ?? true),
    numSpeakers: options.numSpeakers,
    identify: options.identify ?? false,
    history: options.history ?? true,
    picovoiceAccessKey: process.env.PICOVOICE_ACCESS_KEY,
  };
}
