import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function checkFfmpeg(): Promise<void> {
  try {
    await execFileAsync("ffmpeg", ["-version"]);
  } catch {
    throw new Error(
      "ffmpeg is not installed or not in PATH. Install it: https://ffmpeg.org/download.html"
    );
  }
}

export async function getAudioDuration(filePath: string): Promise<number> {
  const { stdout } = await execFileAsync("ffprobe", [
    "-v", "quiet",
    "-show_entries", "format=duration",
    "-of", "csv=p=0",
    filePath,
  ]);
  const duration = parseFloat(stdout.trim());
  if (isNaN(duration)) {
    throw new Error(`Could not determine duration for ${filePath}`);
  }
  return duration;
}

export async function getFileSize(filePath: string): Promise<number> {
  const { stat } = await import("node:fs/promises");
  const stats = await stat(filePath);
  return stats.size;
}

export async function splitAudio(
  inputPath: string,
  outputDir: string,
  segmentDuration: number,
  overlap: number
): Promise<string[]> {
  const duration = await getAudioDuration(inputPath);
  const segments: string[] = [];
  let start = 0;
  let index = 0;

  while (start < duration) {
    const outputPath = `${outputDir}/chunk_${String(index).padStart(3, "0")}.mp3`;
    const segEnd = Math.min(start + segmentDuration + overlap, duration);
    const segLength = segEnd - start;

    await execFileAsync("ffmpeg", [
      "-y",
      "-i", inputPath,
      "-ss", String(start),
      "-t", String(segLength),
      "-acodec", "libmp3lame",
      "-q:a", "4",
      outputPath,
    ]);

    segments.push(outputPath);
    start += segmentDuration;
    index++;
  }

  return segments;
}
