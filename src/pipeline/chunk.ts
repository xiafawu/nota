import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { getFileSize, splitAudio } from "../utils/ffmpeg.js";
import { CHUNK_THRESHOLD_BYTES, SEGMENT_DURATION, OVERLAP_DURATION } from "../constants.js";

export { CHUNK_THRESHOLD_BYTES };

export async function chunkAudio(filePath: string): Promise<string[]> {
  const size = await getFileSize(filePath);

  if (size <= CHUNK_THRESHOLD_BYTES) {
    return [filePath];
  }

  const tempDir = await mkdtemp(path.join(tmpdir(), "meetingsum-"));
  return splitAudio(filePath, tempDir, SEGMENT_DURATION, OVERLAP_DURATION);
}
