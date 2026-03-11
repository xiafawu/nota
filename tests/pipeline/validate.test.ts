import { describe, it, expect, vi } from "vitest";
import { validateInput, checkPython, checkHuggingFaceToken } from "../../src/pipeline/validate.js";

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return {
    ...actual,
    execFile: vi.fn((_cmd: string, _args: string[], cb: (err: null, stdout: string, stderr: string) => void) => {
      cb(null, "", "");
    }),
  };
});

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

describe("checkPython", () => {
  it("does not throw when python3 is available", async () => {
    await expect(checkPython()).resolves.not.toThrow();
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
