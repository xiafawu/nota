import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

/**
 * Resolve the path to Nota's optional dotenv-style config file. NOTA_ENV_FILE
 * overrides the default of ~/.nota/config.
 */
export function defaultEnvFilePath(): string {
  return process.env.NOTA_ENV_FILE ?? path.join(homedir(), ".nota", "config");
}

/**
 * Parse dotenv-style `KEY=VALUE` content into a plain map. Blank lines and
 * lines starting with `#` are ignored, an optional leading `export ` is
 * stripped, and a single matching pair of surrounding single or double quotes
 * is removed. `$VAR` references are NOT expanded. Later duplicate keys
 * overwrite earlier ones.
 */
export function parseEnvFile(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  for (const rawLine of content.split("\n")) {
    const line = rawLine.trim();
    if (line === "" || line.startsWith("#")) continue;

    const withoutExport = line.replace(/^export\s+/, "");
    const eq = withoutExport.indexOf("=");
    if (eq === -1) continue;

    const key = withoutExport.slice(0, eq).trim();
    if (key === "") continue;

    result[key] = unquote(withoutExport.slice(eq + 1));
  }
  return result;
}

function unquote(raw: string): string {
  const trimmed = raw.trim();
  if (
    trimmed.length >= 2 &&
    (trimmed[0] === '"' || trimmed[0] === "'") &&
    trimmed[trimmed.length - 1] === trimmed[0]
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

export interface EnvFileReport {
  applied: string[];
  skipped: string[];
  warnedPerms: boolean;
}

/**
 * Load `KEY=VALUE` pairs from the config file into process.env, filling only
 * keys that are currently unset — real environment variables always win.
 * Idempotent and synchronous so it can run from loadConfig. Warns (once) if the
 * file is group/world-readable. Never logs key values.
 */
export function applyEnvFile(filePath = defaultEnvFilePath()): EnvFileReport {
  const applied: string[] = [];
  const skipped: string[] = [];
  let warnedPerms = false;

  if (!existsSync(filePath)) {
    return { applied, skipped, warnedPerms };
  }

  const mode = statSync(filePath).mode;
  if ((mode & 0o077) !== 0) {
    process.stderr.write(
      `warning: ${filePath} is group/world-readable; run: chmod 600 ${filePath}\n`,
    );
    warnedPerms = true;
  }

  const parsed = parseEnvFile(readFileSync(filePath, "utf-8"));
  for (const [key, value] of Object.entries(parsed)) {
    if (process.env[key] === undefined) {
      process.env[key] = value;
      applied.push(key);
    } else {
      skipped.push(key);
    }
  }

  return { applied, skipped, warnedPerms };
}
