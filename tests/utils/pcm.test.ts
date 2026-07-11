import { mkdtemp, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  decodePcm,
  slicePcm,
  concatToSeconds,
  frames,
  SAMPLE_RATE,
} from "../../src/utils/pcm.js";

const execFileAsync = promisify(execFile);

describe("pcm utils", () => {
  let dir: string;
  let wav: string;

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "nota-pcm-test-"));
    wav = path.join(dir, "tone.wav");
    // 2s 440Hz sine, 16kHz mono — deterministic fixture, no binary committed.
    await execFileAsync("ffmpeg", [
      "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
      "-ar", String(SAMPLE_RATE), "-ac", "1", wav,
    ]);
  });
  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("decodes a wav to ~32000 samples at 16kHz mono", async () => {
    const pcm = await decodePcm(wav);
    expect(pcm).toBeInstanceOf(Int16Array);
    expect(pcm.length).toBeGreaterThan(31000);
    expect(pcm.length).toBeLessThan(33000);
  });

  it("slices PCM by time ranges (seconds → samples)", async () => {
    const pcm = await decodePcm(wav);
    const slice = slicePcm(pcm, [{ start: 0.5, end: 1.0 }]);
    expect(slice.length).toBeGreaterThan(7500);
    expect(slice.length).toBeLessThan(8500);
  });

  it("concatToSeconds trims to the target length", async () => {
    const pcm = await decodePcm(wav);
    const out = concatToSeconds([pcm, pcm], 1); // request 1s out of ~4s available
    expect(out.length).toBe(SAMPLE_RATE);
  });

  it("concatToSeconds returns all samples when shorter than target", () => {
    const a = new Int16Array(100);
    const out = concatToSeconds([a], 1);
    expect(out.length).toBe(100);
  });

  it("frames yields fixed-size windows and drops the trailing partial", () => {
    const pcm = new Int16Array(2050);
    const got = [...frames(pcm, 1000)];
    expect(got.length).toBe(2);
    expect(got[0].length).toBe(1000);
  });
});
