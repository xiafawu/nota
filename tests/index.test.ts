import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";

describe("CLI", () => {
  it("shows help with --help flag", () => {
    const output = execFileSync("npx", ["tsx", "src/index.ts", "--help"], {
      encoding: "utf-8",
    });
    expect(output).toContain("meetingsum");
    expect(output).toContain("--output");
    expect(output).toContain("--language");
    expect(output).toContain("--model");
    expect(output).toContain("--verbose");
  });

  it("shows version with --version flag", () => {
    const output = execFileSync("npx", ["tsx", "src/index.ts", "--version"], {
      encoding: "utf-8",
    });
    expect(output.trim()).toBe("1.0.0");
  });
});
