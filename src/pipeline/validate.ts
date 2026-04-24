import { access } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { checkFfmpeg } from "../utils/ffmpeg.js";

const execFileAsync = promisify(execFile);

const SUPPORTED_EXTENSIONS = new Set([
  ".mp3", ".wav", ".m4a", ".ogg", ".webm", ".flac", ".qta",
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

export async function checkPython(): Promise<void> {
  const pythonBin = process.env.PYTHON_BIN ?? "python3";

  try {
    await execFileAsync(pythonBin, ["--version"]);
  } catch {
    throw new Error(
      `${pythonBin} is not installed or not in PATH. Required for speaker diarization.`
    );
  }

  try {
    await execFileAsync(pythonBin, ["-c", "import importlib.util; exit(0 if importlib.util.find_spec('pyannote.audio') else 1)"]);
  } catch {
    throw new Error(
      `pyannote.audio is not installed for ${pythonBin}. Run: ${pythonBin} -m pip install pyannote.audio torch`
    );
  }
}

export function checkHuggingFaceToken(): void {
  if (!process.env.HUGGINGFACE_TOKEN) {
    throw new Error(
      "HUGGINGFACE_TOKEN environment variable is required for speaker diarization. " +
      "Get one at https://huggingface.co/settings/tokens"
    );
  }
}
