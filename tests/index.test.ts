import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";

describe("CLI", () => {
  it("shows help with --help flag", () => {
    const output = execFileSync("npx", ["tsx", "src/index.ts", "--help"], {
      encoding: "utf-8",
    });
    expect(output).toContain("nota");
    expect(output).toContain("--output");
    expect(output).toContain("--language");
    expect(output).toContain("--model");
    expect(output).toContain("--verbose");
  });

  it("shows --no-diarize in help", () => {
    const output = execFileSync("npx", ["tsx", "src/index.ts", "--help"], {
      encoding: "utf-8",
    });
    expect(output).toContain("--no-diarize");
    expect(output).toContain("--identify");
    expect(output).toContain("--provider");
    expect(output).toContain("--no-history");
  });

  it("shows history commands in help", () => {
    const output = execFileSync(
      "npx",
      ["tsx", "src/index.ts", "history", "--help"],
      {
        encoding: "utf-8",
      },
    );
    expect(output).toContain("list");
    expect(output).toContain("show");
  });

  it("describes speaker show output as embedding metadata", () => {
    const output = execFileSync(
      "npx",
      ["tsx", "src/index.ts", "speakers", "show", "--help"],
      { encoding: "utf-8" },
    );
    expect(output).toContain("embedding dimension");
    expect(output).not.toContain("truncated");
  });

  it("shows version with --version flag", () => {
    const output = execFileSync("npx", ["tsx", "src/index.ts", "--version"], {
      encoding: "utf-8",
    });
    expect(output.trim()).toBe("1.0.0");
  });
});
