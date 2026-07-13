import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  settingsGet,
  settingsList,
  settingsSet,
  settingsUnset,
} from "../../src/cli/settings.js";
import { loadSettings, readRawSettings } from "../../src/utils/settings.js";

let dir: string;
let file: string;
let stdout: string[];
let stderr: string[];
let stdoutSpy: ReturnType<typeof vi.spyOn>;
let stderrSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  dir = mkdtempSync(path.join(tmpdir(), "nota-settings-cli-"));
  file = path.join(dir, "settings.json");
  stdout = [];
  stderr = [];
  stdoutSpy = vi.spyOn(process.stdout, "write").mockImplementation((chunk) => {
    stdout.push(String(chunk));
    return true;
  });
  stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation((chunk) => {
    stderr.push(String(chunk));
    return true;
  });
});

afterEach(() => {
  stdoutSpy.mockRestore();
  stderrSpy.mockRestore();
  rmSync(dir, { recursive: true, force: true });
});

describe("settingsList", () => {
  it("prints effective values with source, defaults when file is absent", () => {
    settingsList(file);
    const rows = stdout.join("");
    expect(rows).toContain("transcription.model\tuniversal\tdefault");
    expect(rows).toContain("summary.model\tgpt-5-mini\tdefault");
    // Header goes to stderr so stdout stays scriptable.
    expect(stderr.join("")).toContain("PATH\tMODEL\tSOURCE");
  });

  it("marks configured entries as settings.json", () => {
    writeFileSync(file, JSON.stringify({ summary: { model: "gpt-4o" } }));
    settingsList(file);
    const rows = stdout.join("");
    expect(rows).toContain("summary.model\tgpt-4o\tsettings.json");
    expect(rows).toContain("transcription.model\tuniversal\tdefault");
  });
});

describe("settingsGet", () => {
  it("prints the default when unset", () => {
    settingsGet("summary.model", file);
    expect(stdout.join("").trim()).toBe("gpt-5-mini");
  });

  it("prints the configured value", () => {
    writeFileSync(file, JSON.stringify({ summary: { model: "gpt-5" } }));
    settingsGet("summary.model", file);
    expect(stdout.join("").trim()).toBe("gpt-5");
  });

  it("throws on an unknown path", () => {
    expect(() => settingsGet("summary.provider", file)).toThrow(
      /Unknown settings path/,
    );
  });
});

describe("settingsSet", () => {
  it("validates and persists a valid model", () => {
    settingsSet("transcription.model", "slam-1", file);
    expect(loadSettings(file)).toMatchObject({
      transcription: { model: "slam-1" },
    });
    expect(stderr.join("")).toContain("Set transcription.model = slam-1");
  });

  it("rejects a model that is invalid for the task, listing valid ids", () => {
    expect(() => settingsSet("summary.model", "universal", file)).toThrow(
      /not a summary model/,
    );
    expect(() => settingsSet("summary.model", "made-up", file)).toThrow(
      /Unknown summary model/,
    );
  });

  it("rejects an unknown path", () => {
    expect(() => settingsSet("foo.bar", "gpt-5", file)).toThrow(
      /Unknown settings path/,
    );
  });

  it("preserves the other task and unknown keys on write", () => {
    writeFileSync(
      file,
      JSON.stringify({ summary: { model: "gpt-5" }, futureKey: 1 }),
    );
    settingsSet("transcription.model", "nano", file);
    const raw = readRawSettings(file);
    expect(raw).toMatchObject({
      summary: { model: "gpt-5" },
      transcription: { model: "nano" },
      futureKey: 1,
    });
  });
});

describe("settingsUnset", () => {
  it("removes the key, reverting to the default", () => {
    writeFileSync(file, JSON.stringify({ summary: { model: "gpt-5" } }));
    settingsUnset("summary.model", file);
    expect(loadSettings(file)).toEqual({});
    settingsGet("summary.model", file);
    expect(stdout.join("").trim()).toBe("gpt-5-mini");
  });

  it("throws on an unknown path", () => {
    expect(() => settingsUnset("nope.model", file)).toThrow(
      /Unknown settings path/,
    );
  });
});
