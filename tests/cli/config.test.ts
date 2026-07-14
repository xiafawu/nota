import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import path from "node:path";
import { tmpdir } from "node:os";
import { printConfig } from "../../src/cli/config.js";

const originalEnv = process.env;
let stdout: string[];

beforeEach(() => {
  process.env = {
    ...originalEnv,
    NOTA_ENV_FILE: path.join(tmpdir(), "nota-config-cli-absent"),
  };
  delete process.env.PICOVOICE_ACCESS_KEY;
  stdout = [];
  vi.spyOn(process.stdout, "write").mockImplementation((chunk: unknown) => {
    stdout.push(String(chunk));
    return true;
  });
  vi.spyOn(process.stderr, "write").mockImplementation(() => true);
});

afterEach(() => {
  process.env = originalEnv;
  vi.restoreAllMocks();
});

describe("printConfig", () => {
  it("does not advertise the removed Picovoice key", async () => {
    await printConfig();
    expect(stdout.join("")).not.toContain("PICOVOICE_ACCESS_KEY");
  });
});
