import {
  DEFAULT_SUMMARY_MODEL,
  DEFAULT_TRANSCRIPTION_MODEL,
  modelsForTask,
  requireModel,
  type ModelTask,
} from "../registry.js";
import {
  defaultSettingsPath,
  loadSettings,
  readRawSettings,
  writeRawSettings,
} from "../utils/settings.js";

const DEFAULT_FOR_TASK: Record<ModelTask, string> = {
  transcription: DEFAULT_TRANSCRIPTION_MODEL,
  summary: DEFAULT_SUMMARY_MODEL,
};

/**
 * Parse and validate a settings dot-path. Only `<task>.model` is supported,
 * where task is `transcription` or `summary`. Throws on anything else so the
 * caller exits non-zero.
 */
function parseTaskPath(dotPath: string): ModelTask {
  const [task, leaf, ...rest] = dotPath.split(".");
  if (
    (task !== "transcription" && task !== "summary") ||
    leaf !== "model" ||
    rest.length > 0
  ) {
    throw new Error(
      `Unknown settings path: ${dotPath}. Valid paths: transcription.model, summary.model`,
    );
  }
  return task;
}

/** `nota settings list` — effective settings + source; rows to stdout. */
export function settingsList(filePath = defaultSettingsPath()): void {
  const settings = loadSettings(filePath);
  process.stderr.write(`Effective settings (file: ${filePath}):\n`);
  process.stderr.write("PATH\tMODEL\tSOURCE\n");

  for (const task of ["transcription", "summary"] as ModelTask[]) {
    const configured = settings[task]?.model;
    const value = configured ?? DEFAULT_FOR_TASK[task];
    const source = configured ? "settings.json" : "default";
    process.stdout.write(`${task}.model\t${value}\t${source}\n`);
  }
}

/** `nota settings get <path>` — print the effective value to stdout. */
export function settingsGet(
  dotPath: string,
  filePath = defaultSettingsPath(),
): void {
  const task = parseTaskPath(dotPath);
  const settings = loadSettings(filePath);
  process.stdout.write(`${settings[task]?.model ?? DEFAULT_FOR_TASK[task]}\n`);
}

/** `nota settings set <path> <value>` — validate + persist. */
export function settingsSet(
  dotPath: string,
  value: string,
  filePath = defaultSettingsPath(),
): void {
  const task = parseTaskPath(dotPath);
  // Throws (listing valid ids) when the model is not valid for this task.
  const entry = requireModel(value, task);

  const raw = readRawSettings(filePath);
  const section =
    raw[task] && typeof raw[task] === "object"
      ? (raw[task] as Record<string, unknown>)
      : {};
  raw[task] = { ...section, model: entry.id };
  writeRawSettings(raw, filePath);

  process.stderr.write(`Set ${task}.model = ${entry.id}\n`);
}

/** `nota settings unset <path>` — remove the key, reverting to the default. */
export function settingsUnset(
  dotPath: string,
  filePath = defaultSettingsPath(),
): void {
  const task = parseTaskPath(dotPath);
  const raw = readRawSettings(filePath);
  const section = raw[task];
  if (section && typeof section === "object") {
    delete (section as Record<string, unknown>).model;
    if (Object.keys(section as Record<string, unknown>).length === 0) {
      delete raw[task];
    }
  }
  writeRawSettings(raw, filePath);

  process.stderr.write(
    `Unset ${task}.model (now ${DEFAULT_FOR_TASK[task]} by default)\n`,
  );
}

// Re-export for consumers/tests that want the picker lists.
export { modelsForTask };
