export interface CLIOptions {
  output?: string;
  language?: string;
  model?: string;
  verbose?: boolean;
}

export interface AppConfig {
  openaiApiKey: string;
  summaryModel: string;
  language?: string;
  verbose: boolean;
}

export function loadConfig(options: CLIOptions): AppConfig {
  const openaiApiKey = process.env.OPENAI_API_KEY;
  if (!openaiApiKey) {
    throw new Error(
      "OPENAI_API_KEY environment variable is required. Get one at https://platform.openai.com/api-keys"
    );
  }

  return {
    openaiApiKey,
    summaryModel: options.model ?? "gpt-4o",
    language: options.language,
    verbose: options.verbose ?? false,
  };
}
