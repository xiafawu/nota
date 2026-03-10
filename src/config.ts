export interface CLIOptions {
  output?: string;
  language?: string;
  model?: string;
  verbose?: boolean;
}

export interface AppConfig {
  openaiApiKey: string;
  anthropicApiKey: string;
  claudeModel: string;
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

  const anthropicApiKey = process.env.ANTHROPIC_API_KEY;
  if (!anthropicApiKey) {
    throw new Error(
      "ANTHROPIC_API_KEY environment variable is required. Get one at https://console.anthropic.com/"
    );
  }

  return {
    openaiApiKey,
    anthropicApiKey,
    claudeModel: options.model ?? "claude-sonnet-4-20250514",
    language: options.language,
    verbose: options.verbose ?? false,
  };
}
