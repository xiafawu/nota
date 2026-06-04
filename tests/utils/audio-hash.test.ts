import { mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { hashFile } from "../../src/utils/audio-hash.js";

describe("hashFile", () => {
  let dir: string;

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "nota-hash-test-"));
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("matches the known SHA-256 of 'abc'", async () => {
    const file = path.join(dir, "abc.bin");
    await writeFile(file, "abc");
    // NIST FIPS 180-2 test vector.
    expect(await hashFile(file)).toBe(
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
  });

  it("is stable across repeated reads of the same bytes", async () => {
    const file = path.join(dir, "stable.bin");
    await writeFile(file, "the same bytes every time");
    expect(await hashFile(file)).toBe(await hashFile(file));
  });

  it("differs when a single byte changes", async () => {
    const a = path.join(dir, "a.bin");
    const b = path.join(dir, "b.bin");
    await writeFile(a, "audio-payload-0");
    await writeFile(b, "audio-payload-1");
    expect(await hashFile(a)).not.toBe(await hashFile(b));
  });

  it("rejects for a missing file", async () => {
    await expect(hashFile(path.join(dir, "nope.bin"))).rejects.toThrow();
  });
});
