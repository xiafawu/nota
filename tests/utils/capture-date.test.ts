import { mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { resolveCaptureDate } from "../../src/utils/capture-date.js";

const execFileAsync = promisify(execFile);

describe("resolveCaptureDate", () => {
  let dir: string;
  let taggedAudio: string;
  let plainFile: string;

  beforeAll(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "nota-capture-test-"));
    taggedAudio = path.join(dir, "tagged.m4a");
    plainFile = path.join(dir, "plain.bin");

    // 1s of silence with an embedded creation_time tag.
    await execFileAsync("ffmpeg", [
      "-y",
      "-f", "lavfi",
      "-i", "anullsrc=r=8000:cl=mono",
      "-t", "1",
      "-metadata", "creation_time=2020-01-02T03:04:05.000000Z",
      taggedAudio,
    ]);

    await writeFile(plainFile, "not audio data");
  });

  afterAll(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("reads creation_time from container metadata", async () => {
    const date = await resolveCaptureDate(taggedAudio);
    expect(date).not.toBeNull();
    expect(date!.toISOString().split("T")[0]).toBe("2020-01-02");
  });

  it("falls back to filesystem birthtime when no metadata tag", async () => {
    const date = await resolveCaptureDate(plainFile);
    expect(date).not.toBeNull();
    expect(date!.getFullYear()).toBe(new Date().getFullYear());
  });

  it("returns null for a nonexistent file", async () => {
    const date = await resolveCaptureDate(path.join(dir, "nope.m4a"));
    expect(date).toBeNull();
  });
});
