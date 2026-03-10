import { describe, it, expect } from "vitest";
import { checkFfmpeg, getAudioDuration } from "../../src/utils/ffmpeg.js";

describe("checkFfmpeg", () => {
  it("resolves if ffmpeg is installed", async () => {
    await expect(checkFfmpeg()).resolves.not.toThrow();
  });
});

describe("getAudioDuration", () => {
  it("throws for nonexistent file", async () => {
    await expect(getAudioDuration("/tmp/nonexistent.mp3")).rejects.toThrow();
  });
});
