import { access } from "node:fs/promises";
import path from "node:path";
import { checkFfmpeg } from "../utils/ffmpeg.js";

const SUPPORTED_EXTENSIONS = new Set([
  ".mp3", ".wav", ".m4a", ".ogg", ".webm", ".flac",
]);

export async function validateInput(filePath: string): Promise<void> {
  // Check file exists
  try {
    await access(filePath);
  } catch {
    throw new Error(`File does not exist: ${filePath}`);
  }

  // Check extension
  const ext = path.extname(filePath).toLowerCase();
  if (!SUPPORTED_EXTENSIONS.has(ext)) {
    throw new Error(
      `Unsupported audio format: ${ext}. Supported: ${[...SUPPORTED_EXTENSIONS].join(", ")}`
    );
  }

  // Check ffmpeg
  await checkFfmpeg();
}
