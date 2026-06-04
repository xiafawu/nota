import { mkdtemp, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import { decodePcm } from "../../src/utils/pcm.js";
import {
  isEagleAvailable,
  enrollProfile,
  recognize,
} from "../../src/pipeline/eagle.js";

const execFileAsync = promisify(execFile);
const KEY = process.env.PICOVOICE_ACCESS_KEY;

describe("eagle", () => {
  it("isEagleAvailable reflects the AccessKey", () => {
    expect(isEagleAvailable(KEY)).toBe(Boolean(KEY));
    expect(isEagleAvailable(undefined)).toBe(false);
    expect(isEagleAvailable("  ")).toBe(false);
  });

  it("recognize returns empty when there are no profiles", () => {
    expect(recognize("anything", { "Speaker 1": new Int16Array(16000) }, [])).toEqual({});
  });

  it.skipIf(!KEY)("enrolls from speech PCM and recognizes the same voice high", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "nota-eagle-test-"));
    try {
      const wav = path.join(dir, "spk.wav");
      // Speech-like fixture. A pure tone may not satisfy Eagle's voice
      // detector; if enrollment never reaches 100% here, swap to a committed
      // spoken-word fixture (see plan Task 2 Step 4 note).
      await execFileAsync("ffmpeg", [
        "-y", "-f", "lavfi", "-i", "sine=frequency=180:duration=30",
        "-ar", "16000", "-ac", "1", wav,
      ]);
      const pcm = await decodePcm(wav);
      const profile = await enrollProfile(KEY!, pcm);
      expect(profile).toBeInstanceOf(Uint8Array);
      expect(profile.length).toBeGreaterThan(0);

      const scores = recognize(KEY!, { "Speaker 1": pcm }, [profile]);
      expect(scores["Speaker 1"].index).toBe(0);
      expect(scores["Speaker 1"].score).toBeGreaterThan(0.5);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
