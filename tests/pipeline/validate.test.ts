import { describe, it, expect } from "vitest";
import { validateInput, checkHuggingFaceToken } from "../../src/pipeline/validate.js";

describe("validateInput", () => {
  it("throws for nonexistent file", async () => {
    await expect(validateInput("/tmp/does-not-exist.mp3")).rejects.toThrow(
      "does not exist"
    );
  });

  it("throws for unsupported extension", async () => {
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

describe("checkPython", () => {
  it("does not throw for python3 --version check", async () => {
    // Dynamic import to avoid needing file-level mock
    const { checkPython } = await import("../../src/pipeline/validate.js");
    try {
      await checkPython();
    } catch (e: any) {
      // It's OK if it throws about pyannote not being installed
      // What matters is it doesn't throw about python3 not being found
      expect(e.message).toContain("pyannote");
      expect(e.message).not.toContain("python3 is not installed");
    }
  });
});

describe("checkHuggingFaceToken", () => {
  it("throws when HUGGINGFACE_TOKEN is not set", () => {
    const original = process.env.HUGGINGFACE_TOKEN;
    delete process.env.HUGGINGFACE_TOKEN;
    try {
      expect(() => checkHuggingFaceToken()).toThrow("HUGGINGFACE_TOKEN");
    } finally {
      if (original) process.env.HUGGINGFACE_TOKEN = original;
    }
  });
});
