import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";

/**
 * Compute the SHA-256 of a file's raw bytes, streamed so large audio files
 * never have to sit fully in memory. Returns a lowercase hex digest.
 *
 * This is a *byte* hash, not an acoustic fingerprint: it detects the exact
 * same file (e.g. the same Voice Memo shared twice), not the same recording
 * re-encoded to a different container/bitrate. That trade-off is intentional —
 * the byte hash is cheap and gates paid transcription calls on the common case.
 */
export async function hashFile(filePath: string): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const hash = createHash("sha256");
    const stream = createReadStream(filePath);
    stream.on("error", reject);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}
