import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { stat } from "node:fs/promises";

const execFileAsync = promisify(execFile);

/**
 * Resolve when the audio was captured (recorded), independent of when Nota
 * processes it. Tries container metadata first (the creation_time tag survives
 * copy/AirDrop/download), then falls back to the file's on-disk birth time.
 * Returns null when neither source yields a usable date.
 */
export async function resolveCaptureDate(
  filePath: string,
): Promise<Date | null> {
  const fromMetadata = await captureFromMetadata(filePath);
  if (fromMetadata) return fromMetadata;

  const fromBirthtime = await captureFromBirthtime(filePath);
  if (fromBirthtime) return fromBirthtime;

  return null;
}

async function captureFromMetadata(filePath: string): Promise<Date | null> {
  try {
    const { stdout } = await execFileAsync("ffprobe", [
      "-v", "quiet",
      "-show_entries", "format_tags=creation_time",
      "-of", "default=nw=1:nk=1",
      filePath,
    ]);
    const value = stdout.trim();
    if (!value) return null;
    const date = new Date(value);
    return isNaN(date.getTime()) ? null : date;
  } catch {
    return null;
  }
}

async function captureFromBirthtime(filePath: string): Promise<Date | null> {
  try {
    const stats = await stat(filePath);
    const ms = stats.birthtimeMs;
    if (!ms || ms <= 0) return null;
    const date = new Date(ms);
    return isNaN(date.getTime()) ? null : date;
  } catch {
    return null;
  }
}
