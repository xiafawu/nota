import { describe, it, expect, vi } from "vitest";
import { validateInput } from "../../src/pipeline/validate.js";

describe("validateInput", () => {
  it("throws for nonexistent file", async () => {
    await expect(validateInput("/tmp/does-not-exist.mp3")).rejects.toThrow(
      "does not exist"
    );
  });

  it("throws for unsupported extension", async () => {
    // Create a temp file with bad extension
    const { writeFile, unlink } = await import("node:fs/promises");
    const path = "/tmp/test-validate.txt";
    await writeFile(path, "fake");
    try {
      await expect(validateInput(path)).rejects.toThrow("Unsupported");
    } finally {
      await unlink(path);
    }
  });
});
