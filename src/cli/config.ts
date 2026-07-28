import { existsSync, readFileSync } from "node:fs";
import { defaultEnvFilePath, parseEnvFile } from "../utils/env-file.js";
import { CLI_BINARY, CLI_PROVIDERS } from "../cli-engines.js";
import { probeCliEngine, type CliProbe } from "../pipeline/cli-engine.js";

type KeySource = "env" | "file" | "absent";

/**
 * Keys Nota knows about. The display set is the union of these with whatever
 * else lives in the config file, so future providers show up with no code
 * change once their key is added to ~/.nota/config.
 */
const KNOWN_KEYS = [
  "OPENAI_API_KEY",
  "ASSEMBLYAI_API_KEY",
  "HUGGINGFACE_TOKEN",
  "GEMINI_API_KEY",
  "DEEPSEEK_API_KEY",
  "OPENROUTER_API_KEY",
];

function resolveSource(
  key: string,
  fileMap: Record<string, string>,
): KeySource {
  const envVal = process.env[key];
  const fileHas = Object.prototype.hasOwnProperty.call(fileMap, key);

  if (envVal !== undefined && (!fileHas || envVal !== fileMap[key])) {
    return "env";
  }
  if (envVal !== undefined && fileHas && envVal === fileMap[key]) {
    return "file";
  }
  if (fileHas) {
    return "file";
  }
  return "absent";
}

function maskValue(value: string): string {
  if (value.length <= 6) return "••••";
  return `${value.slice(0, 2)}…${value.slice(-4)}`;
}

/** Injected by tests so `nota config` never spawns the real CLIs. */
export type CliProbeFn = (typeof probeCliEngine);

export interface PrintConfigOptions {
  probe?: CliProbeFn;
}

/**
 * Report which API keys resolve and from where (env vs ~/.nota/config), with
 * values masked so secrets are never printed. Data rows go to stdout so the
 * output stays scriptable; the header and hints go to stderr. Reads the config
 * file directly and does not mutate process.env.
 *
 * CLI summary engines get their own block: their precondition is not a key at
 * all but a binary and a login (ADR 0003), and a diagnostics command that
 * listed only keys would answer "everything resolves" on a machine where
 * `claude-code/sonnet` cannot run at all.
 *
 * The test seam is a field on an options **object**, not a bare parameter with
 * a default: this function is Commander's action handler, and Commander invokes
 * an action with `(options, command)`. A bare `probe = probeCliEngine` parameter
 * was therefore overwritten by Commander's own options object on every real
 * `nota config`, which crashed with "probe is not a function". A bag whose
 * `probe` field is simply absent falls through to the default instead.
 */
export async function printConfig(
  options: PrintConfigOptions = {},
): Promise<void> {
  const probe = options.probe ?? probeCliEngine;
  const filePath = defaultEnvFilePath();
  const fileExists = existsSync(filePath);
  let fileMap: Record<string, string> = {};
  if (fileExists) {
    try {
      fileMap = parseEnvFile(readFileSync(filePath, "utf-8"));
    } catch {
      fileMap = {};
    }
  }

  process.stderr.write(`API key resolution (config file: ${filePath}):\n`);
  process.stderr.write("KEY\tSOURCE\tVALUE\n");

  const displayKeys = Array.from(
    new Set([...KNOWN_KEYS, ...Object.keys(fileMap)]),
  ).sort();

  for (const key of displayKeys) {
    const source = resolveSource(key, fileMap);
    const envVal = process.env[key];
    const resolved =
      envVal !== undefined
        ? envVal
        : Object.prototype.hasOwnProperty.call(fileMap, key)
          ? fileMap[key]
          : undefined;
    const masked = resolved === undefined ? "absent" : maskValue(resolved);
    process.stdout.write(`${key}\t${source}\t${masked}\n`);
  }

  if (!fileExists) {
    process.stderr.write(
      "No ~/.nota/config found; create it (chmod 600) or set env vars.\n",
    );
  }

  process.stderr.write(
    "\nCLI summary engines (no API key — the CLI's own login; ADR 0003):\n",
  );
  process.stderr.write("ENGINE\tBINARY\tSTATUS\n");
  const probes: CliProbe[] = await Promise.all(
    CLI_PROVIDERS.map((provider) => probe(provider)),
  );
  for (const p of probes) {
    // The version string doubles as the "found" answer, so one column carries
    // both — `not found on PATH …` is exactly as informative as a version.
    process.stdout.write(`${p.provider}\t${CLI_BINARY[p.provider]}\t${p.detail}\n`);
  }
}
