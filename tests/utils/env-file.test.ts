import { afterEach, describe, expect, it, vi } from "vitest";
import {
  chmodSync,
  mkdtempSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { applyEnvFile, parseEnvFile } from "../../src/utils/env-file.js";

describe("parseEnvFile", () => {
  it("parses a bare KEY=VALUE line", () => {
    expect(parseEnvFile("A=1")).toEqual({ A: "1" });
  });

  it("strips a leading export", () => {
    expect(parseEnvFile("export B=2")).toEqual({ B: "2" });
  });

  it("ignores comment lines and blank lines", () => {
    expect(parseEnvFile("# a comment\n\n   \nA=1")).toEqual({ A: "1" });
  });

  it("strips a matching pair of double quotes and keeps inner spaces", () => {
    expect(parseEnvFile('C="x y"')).toEqual({ C: "x y" });
  });

  it("strips a matching pair of single quotes", () => {
    expect(parseEnvFile("D='z'")).toEqual({ D: "z" });
  });

  it("splits on the first = so values may contain =", () => {
    expect(parseEnvFile("E=a=b")).toEqual({ E: "a=b" });
  });

  it("ignores a line without an =", () => {
    expect(parseEnvFile("NOT_A_PAIR")).toEqual({});
  });

  it("trims surrounding whitespace around key and value", () => {
    expect(parseEnvFile("   F   =   g   ")).toEqual({ F: "g" });
  });

  it("lets later duplicate keys overwrite earlier ones", () => {
    expect(parseEnvFile("A=1\nA=2")).toEqual({ A: "2" });
  });

  it("does not expand $VAR references", () => {
    expect(parseEnvFile("G=$HOME")).toEqual({ G: "$HOME" });
  });
});

describe("applyEnvFile", () => {
  const touchedKeys: string[] = [];
  let tempDir: string | undefined;

  function trackDelete(key: string): void {
    touchedKeys.push(key);
    delete process.env[key];
  }

  function trackSet(key: string, value: string): void {
    touchedKeys.push(key);
    process.env[key] = value;
  }

  function makeTempFile(name: string, content: string): string {
    tempDir = mkdtempSync(path.join(tmpdir(), "nota-env-file-"));
    const filePath = path.join(tempDir, name);
    writeFileSync(filePath, content, "utf-8");
    return filePath;
  }

  afterEach(() => {
    for (const key of touchedKeys) delete process.env[key];
    touchedKeys.length = 0;
    if (tempDir) {
      rmSync(tempDir, { recursive: true, force: true });
      tempDir = undefined;
    }
  });

  it("lets real env vars win and fills only unset keys", () => {
    const filePath = makeTempFile(
      "config",
      "NOTA_TEST_X=file\nNOTA_TEST_Y=file\n",
    );
    trackSet("NOTA_TEST_X", "env");
    trackDelete("NOTA_TEST_Y");
    chmodSync(filePath, 0o600);

    const report = applyEnvFile(filePath);

    expect(process.env.NOTA_TEST_X).toBe("env");
    expect(process.env.NOTA_TEST_Y).toBe("file");
    expect(report.skipped).toContain("NOTA_TEST_X");
    expect(report.applied).toContain("NOTA_TEST_Y");
  });

  it("returns an empty report for a missing file and does not throw", () => {
    tempDir = mkdtempSync(path.join(tmpdir(), "nota-env-file-"));
    const filePath = path.join(tempDir, "does-not-exist");
    const report = applyEnvFile(filePath);
    expect(report).toEqual({ applied: [], skipped: [], warnedPerms: false });
  });

  it("warns when the file is group/world-readable", () => {
    const filePath = makeTempFile("config", "NOTA_TEST_Z=file\n");
    trackDelete("NOTA_TEST_Z");
    chmodSync(filePath, 0o644);

    const stderrSpy = vi
      .spyOn(process.stderr, "write")
      .mockImplementation(() => true);
    const report = applyEnvFile(filePath);
    stderrSpy.mockRestore();

    // Tolerate filesystems that silently ignore chmod (rare CI setups).
    if ((statSync(filePath).mode & 0o077) !== 0) {
      expect(report.warnedPerms).toBe(true);
    } else {
      expect(report.warnedPerms).toBe(false);
    }
    expect(process.env.NOTA_TEST_Z).toBe("file");
  });
});
