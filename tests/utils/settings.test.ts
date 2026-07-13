import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  loadSettings,
  readRawSettings,
  writeRawSettings,
} from "../../src/utils/settings.js";

let dir: string;
let file: string;
let stderrSpy: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  dir = mkdtempSync(path.join(tmpdir(), "nota-settings-"));
  file = path.join(dir, "settings.json");
  stderrSpy = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
});

afterEach(() => {
  stderrSpy.mockRestore();
  rmSync(dir, { recursive: true, force: true });
});

describe("loadSettings", () => {
  it("returns {} when the file is missing", () => {
    expect(loadSettings(file)).toEqual({});
  });

  it("loads valid transcription + summary models", () => {
    writeFileSync(
      file,
      JSON.stringify({
        transcription: { model: "whisper-1" },
        summary: { model: "gemini-2.5-flash" },
      }),
    );
    expect(loadSettings(file)).toEqual({
      transcription: { model: "whisper-1" },
      summary: { model: "gemini-2.5-flash" },
    });
  });

  it("drops entries with unknown or wrong-task models (warning, no throw)", () => {
    writeFileSync(
      file,
      JSON.stringify({
        transcription: { model: "gpt-4o" }, // summary model, wrong task
        summary: { model: "made-up" }, // unknown
      }),
    );
    expect(loadSettings(file)).toEqual({});
    expect(stderrSpy).toHaveBeenCalled();
  });

  it("ignores a corrupt JSON file", () => {
    writeFileSync(file, "{ not json");
    expect(loadSettings(file)).toEqual({});
    expect(stderrSpy).toHaveBeenCalled();
  });
});

describe("writeRawSettings / readRawSettings", () => {
  it("round-trips and preserves unknown keys", () => {
    writeRawSettings(
      { summary: { model: "gpt-5" }, futureKey: { nested: true } },
      file,
    );
    expect(existsSync(file)).toBe(true);
    const raw = readRawSettings(file);
    expect(raw).toMatchObject({
      summary: { model: "gpt-5" },
      futureKey: { nested: true },
    });
    // Trailing newline for a tidy file.
    expect(readFileSync(file, "utf-8").endsWith("\n")).toBe(true);
  });
});
