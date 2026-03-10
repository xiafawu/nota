import { describe, it, expect } from "vitest";
import { chunkAudio, CHUNK_THRESHOLD_BYTES } from "../../src/pipeline/chunk.js";

describe("chunkAudio", () => {
  it("exports the chunk threshold constant", () => {
    expect(CHUNK_THRESHOLD_BYTES).toBe(20 * 1024 * 1024);
  });
});

describe("chunkAudio", () => {
  it("returns single-element array for small files", async () => {
    // Create a tiny temp file
    const { writeFile, unlink } = await import("node:fs/promises");
    const path = "/tmp/test-tiny.mp3";
    await writeFile(path, Buffer.alloc(100));
    try {
      const chunks = await chunkAudio(path);
      expect(chunks).toEqual([path]);
    } finally {
      await unlink(path);
    }
  });
});
