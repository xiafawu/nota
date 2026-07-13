import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { getModel, type ModelTask } from "../registry.js";

/**
 * Non-secret user preferences for Nota, persisted at `~/.nota/settings.json`.
 * Secrets never live here — API keys stay in `~/.nota/config`. Shape is exactly:
 *   { "transcription": { "model": "..." }, "summary": { "model": "..." } }
 */
export interface NotaSettings {
  transcription?: { model: string };
  summary?: { model: string };
}

/** Tasks that own a `<task>.model` setting, in display order. */
export const SETTING_TASKS: ModelTask[] = ["transcription", "summary"];

/**
 * Resolve the settings file path. NOTA_SETTINGS_FILE overrides the default of
 * ~/.nota/settings.json (used to keep tests hermetic).
 */
export function defaultSettingsPath(): string {
  return (
    process.env.NOTA_SETTINGS_FILE ??
    path.join(homedir(), ".nota", "settings.json")
  );
}

/**
 * Read the raw settings object off disk without registry validation. Missing
 * or unparseable file yields `{}`. Used by writers so unknown JSON keys survive
 * a round-trip.
 */
export function readRawSettings(
  filePath = defaultSettingsPath(),
): Record<string, unknown> {
  if (!existsSync(filePath)) return {};
  try {
    const parsed = JSON.parse(readFileSync(filePath, "utf-8"));
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : {};
  } catch {
    process.stderr.write(
      `warning: ${filePath} is not valid JSON; ignoring it.\n`,
    );
    return {};
  }
}

/**
 * Load and validate settings against the registry. A missing file is an empty
 * settings object. Entries whose model is unknown or belongs to another task
 * are warned about on stderr and dropped (never throw).
 */
export function loadSettings(filePath = defaultSettingsPath()): NotaSettings {
  const raw = readRawSettings(filePath);
  const result: NotaSettings = {};

  for (const task of SETTING_TASKS) {
    const section = raw[task];
    if (section === undefined) continue;
    const model =
      section && typeof section === "object"
        ? (section as Record<string, unknown>).model
        : undefined;
    if (typeof model !== "string") {
      process.stderr.write(
        `warning: ignoring settings.${task}: expected { "model": "<id>" }.\n`,
      );
      continue;
    }
    const entry = getModel(model);
    if (!entry || entry.task !== task) {
      process.stderr.write(
        `warning: ignoring settings.${task}.model=${model}: not a valid ${task} model.\n`,
      );
      continue;
    }
    result[task] = { model };
  }

  return result;
}

/**
 * Atomically write a raw settings object (preserving any unknown keys the
 * caller kept) by writing to a temp file and renaming over the target.
 */
export function writeRawSettings(
  settings: Record<string, unknown>,
  filePath = defaultSettingsPath(),
): void {
  mkdirSync(path.dirname(filePath), { recursive: true });
  const tmp = `${filePath}.tmp-${process.pid}-${Date.now()}`;
  writeFileSync(tmp, `${JSON.stringify(settings, null, 2)}\n`, "utf-8");
  renameSync(tmp, filePath);
}
