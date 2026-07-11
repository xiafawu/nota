import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  deleteSpeaker,
  listSpeakers,
  mergeSpeakers,
  reassignVoiceprint,
  renameSpeaker,
  showSpeaker,
} from "../../src/cli/speakers.js";
import type {
  SpeakerStore,
  Voiceprint,
} from "../../src/pipeline/speakers.js";

let tempDir: string;
let storePath: string;
let stdoutSpy: ReturnType<typeof vi.spyOn>;
let stderrSpy: ReturnType<typeof vi.spyOn>;
let stdoutChunks: string[];
let stderrChunks: string[];

// A 4-byte Eagle profile blob, base64-encoded. `decodeProfile(PROFILE).length`
// is 4, which the list/show surfaces report as the profile size.
const PROFILE = Buffer.from([1, 2, 3, 4]).toString("base64");

function writeStore(store: SpeakerStore): void {
  writeFileSync(storePath, JSON.stringify(store), "utf-8");
}

function readStore(): SpeakerStore {
  return JSON.parse(readFileSync(storePath, "utf-8")) as SpeakerStore;
}

function vp(id: string, source = "demo.mp3", profile = PROFILE): Voiceprint {
  return { id, profile, enrolledAt: id, source };
}

beforeEach(() => {
  tempDir = mkdtempSync(path.join(tmpdir(), "nota-speakers-cli-"));
  storePath = path.join(tempDir, "speakers.json");
  stdoutChunks = [];
  stderrChunks = [];
  stdoutSpy = vi
    .spyOn(process.stdout, "write")
    .mockImplementation((chunk: unknown) => {
      stdoutChunks.push(typeof chunk === "string" ? chunk : String(chunk));
      return true;
    });
  stderrSpy = vi
    .spyOn(process.stderr, "write")
    .mockImplementation((chunk: unknown) => {
      stderrChunks.push(typeof chunk === "string" ? chunk : String(chunk));
      return true;
    });
});

afterEach(() => {
  stdoutSpy.mockRestore();
  stderrSpy.mockRestore();
  rmSync(tempDir, { recursive: true, force: true });
});

describe("listSpeakers", () => {
  it("prints empty notice on stderr when no speakers are enrolled", async () => {
    await listSpeakers({ storePath });
    expect(stdoutChunks.join("")).toBe("");
    expect(stderrChunks.join("")).toContain("No speakers enrolled.");
  });

  it("prints one tab-separated row per voiceprint with profile byte size", async () => {
    writeStore({
      version: 3,
      speakers: {
        Alice: {
          voiceprints: [
            vp("2026-01-01T00:00:00.000Z", "demo.mp3"),
            vp("2026-02-15T00:00:00.000Z", "later.mp3"),
          ],
        },
      },
    });

    await listSpeakers({ storePath });
    const lines = stdoutChunks.join("").trim().split("\n");
    expect(lines).toHaveLength(2);
    const [name, vpId, enrolledAt, source, bytes] = lines[0].split("\t");
    expect(name).toBe("Alice");
    expect(vpId).toBe("2026-01-01T00:00:00.000Z");
    expect(enrolledAt).toBe("2026-01-01T00:00:00.000Z");
    expect(source).toBe("demo.mp3");
    expect(bytes).toBe("4"); // 4-byte profile blob

    expect(lines[1].split("\t")[1]).toBe("2026-02-15T00:00:00.000Z");
  });

  it("drops legacy embedding-only records (no Eagle profile) on load", async () => {
    // Pre-Eagle stores held pyannote `embedding` vectors with no `profile`.
    // Those cannot be converted to an Eagle profile and are dropped on load.
    writeFileSync(
      storePath,
      JSON.stringify({
        version: 2,
        speakers: {
          Alice: {
            voiceprints: [
              { id: "x", embedding: [1, 0, 0, 0], enrolledAt: "x", source: "legacy.mp3" },
            ],
          },
        },
      }),
      "utf-8",
    );

    await listSpeakers({ storePath });
    expect(stdoutChunks.join("")).toBe("");
    expect(stderrChunks.join("")).toContain("No speakers enrolled.");
  });
});

describe("renameSpeaker", () => {
  it("throws when the source profile does not exist", async () => {
    writeStore({ version: 3, speakers: {} });
    await expect(renameSpeaker("Ghost", "Bob", { storePath })).rejects.toThrow(/Ghost/);
  });

  it("renames an existing profile and persists the change", async () => {
    writeStore({
      version: 3,
      speakers: { Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "demo.mp3")] } },
    });

    await renameSpeaker("Alice", "Alicia", { storePath });
    const after = readStore();
    expect(after.speakers.Alice).toBeUndefined();
    expect(after.speakers.Alicia).toBeDefined();
    expect(after.speakers.Alicia.voiceprints[0].profile).toBe(PROFILE);
  });

  it("refuses to overwrite an existing destination", async () => {
    writeStore({
      version: 3,
      speakers: {
        Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "a.mp3")] },
        Bob: { voiceprints: [vp("2026-01-01T00:00:00.001Z", "b.mp3")] },
      },
    });

    await expect(renameSpeaker("Alice", "Bob", { storePath })).rejects.toThrow(/Bob/);
  });
});

describe("deleteSpeaker", () => {
  it("removes the named speaker from disk", async () => {
    writeStore({
      version: 3,
      speakers: {
        Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "demo.mp3")] },
        Bob: { voiceprints: [vp("2026-01-01T00:00:00.001Z", "demo.mp3")] },
      },
    });

    await deleteSpeaker("Alice", { storePath });
    const after = readStore();
    expect(after.speakers.Alice).toBeUndefined();
    expect(after.speakers.Bob).toBeDefined();
  });

  it("throws when the speaker is not enrolled", async () => {
    writeStore({ version: 3, speakers: {} });
    await expect(deleteSpeaker("Ghost", { storePath })).rejects.toThrow(/Ghost/);
  });
});

describe("mergeSpeakers", () => {
  it("concatenates voiceprints (no averaging) and drops the source", async () => {
    writeStore({
      version: 3,
      speakers: {
        Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "a.mp3")] },
        AliceAlt: {
          voiceprints: [
            vp("2026-02-01T00:00:00.000Z", "b.mp3"),
            vp("2026-03-01T00:00:00.000Z", "c.mp3"),
          ],
        },
      },
    });

    await mergeSpeakers("AliceAlt", "Alice", { storePath });
    const after = readStore();
    expect(after.speakers.AliceAlt).toBeUndefined();
    expect(after.speakers.Alice.voiceprints).toHaveLength(3);

    const ids = after.speakers.Alice.voiceprints.map((v) => v.id);
    expect(ids).toContain("2026-01-01T00:00:00.000Z");
    expect(ids).toContain("2026-02-01T00:00:00.000Z");
    expect(ids).toContain("2026-03-01T00:00:00.000Z");
    const first = after.speakers.Alice.voiceprints.find(
      (v) => v.id === "2026-01-01T00:00:00.000Z",
    );
    expect(first?.profile).toBe(PROFILE);
  });

  it("dedupes voiceprints with the same id (idempotent re-merge)", async () => {
    writeStore({
      version: 3,
      speakers: {
        Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "a.mp3")] },
        AliceAlt: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "a.mp3")] },
      },
    });

    await mergeSpeakers("AliceAlt", "Alice", { storePath });
    expect(readStore().speakers.Alice.voiceprints).toHaveLength(1);
  });

  it("throws when either profile is missing", async () => {
    writeStore({
      version: 3,
      speakers: { Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "a.mp3")] } },
    });
    await expect(mergeSpeakers("Alice", "Ghost", { storePath })).rejects.toThrow(/Ghost/);
    await expect(mergeSpeakers("Ghost", "Alice", { storePath })).rejects.toThrow(/Ghost/);
  });

  it("rejects merging a speaker into itself", async () => {
    writeStore({
      version: 3,
      speakers: { Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "a.mp3")] } },
    });
    await expect(mergeSpeakers("Alice", "Alice", { storePath })).rejects.toThrow(/itself/);
  });
});

describe("reassignVoiceprint", () => {
  it("moves a voiceprint from one existing speaker to another", async () => {
    writeStore({
      version: 3,
      speakers: {
        Alice: {
          voiceprints: [
            vp("2026-01-01T00:00:00.000Z", "a.mp3"),
            vp("2026-02-01T00:00:00.000Z", "b.mp3"),
          ],
        },
        Bob: { voiceprints: [vp("2026-01-15T00:00:00.000Z", "c.mp3")] },
      },
    });

    await reassignVoiceprint("2026-02-01T00:00:00.000Z", "Bob", { storePath });
    const after = readStore();
    expect(after.speakers.Alice.voiceprints).toHaveLength(1);
    expect(after.speakers.Alice.voiceprints[0].id).toBe("2026-01-01T00:00:00.000Z");
    expect(after.speakers.Bob.voiceprints).toHaveLength(2);
    expect(
      after.speakers.Bob.voiceprints.some((v) => v.id === "2026-02-01T00:00:00.000Z"),
    ).toBe(true);
  });

  it("creates the destination profile when it does not exist", async () => {
    writeStore({
      version: 3,
      speakers: {
        Alice: {
          voiceprints: [
            vp("2026-01-01T00:00:00.000Z", "a.mp3"),
            vp("2026-02-01T00:00:00.000Z", "b.mp3"),
          ],
        },
      },
    });

    await reassignVoiceprint("2026-02-01T00:00:00.000Z", "Carol", { storePath });
    const after = readStore();
    expect(after.speakers.Carol).toBeDefined();
    expect(after.speakers.Carol.voiceprints).toHaveLength(1);
    expect(after.speakers.Carol.voiceprints[0].source).toBe("b.mp3");
    expect(after.speakers.Alice.voiceprints).toHaveLength(1);
  });

  it("drops the source profile when reassigning its last voiceprint", async () => {
    writeStore({
      version: 3,
      speakers: { Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "a.mp3")] } },
    });

    await reassignVoiceprint("2026-01-01T00:00:00.000Z", "Bob", { storePath });
    const after = readStore();
    expect(after.speakers.Alice).toBeUndefined();
    expect(after.speakers.Bob).toBeDefined();
    expect(after.speakers.Bob.voiceprints).toHaveLength(1);
  });

  it("throws when the voiceprint id does not exist", async () => {
    writeStore({
      version: 3,
      speakers: { Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "a.mp3")] } },
    });

    await expect(
      reassignVoiceprint("nonexistent-id", "Bob", { storePath }),
    ).rejects.toThrow(/nonexistent-id/);
  });

  it("is a no-op when reassigning to the voiceprint's current owner", async () => {
    writeStore({
      version: 3,
      speakers: { Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z", "a.mp3")] } },
    });

    await reassignVoiceprint("2026-01-01T00:00:00.000Z", "Alice", { storePath });
    const after = readStore();
    expect(after.speakers.Alice.voiceprints).toHaveLength(1);
    expect(stderrChunks.join("")).toContain("already belongs");
  });
});

describe("showSpeaker", () => {
  it("prints a JSON view with the profile byte size per voiceprint", async () => {
    writeStore({
      version: 3,
      speakers: {
        Alice: {
          voiceprints: [
            vp("2026-01-01T00:00:00.000Z", "demo.mp3"),
            vp("2026-02-01T00:00:00.000Z", "later.mp3"),
          ],
        },
      },
    });

    await showSpeaker("Alice", { storePath });
    const parsed = JSON.parse(stdoutChunks.join(""));
    expect(parsed.name).toBe("Alice");
    expect(parsed.voiceprintCount).toBe(2);
    expect(parsed.voiceprints).toHaveLength(2);
    expect(parsed.voiceprints[0].profileBytes).toBe(4);
    expect(parsed.voiceprints[0].id).toBe("2026-01-01T00:00:00.000Z");
  });

  it("throws when the speaker is missing", async () => {
    writeStore({ version: 3, speakers: {} });
    await expect(showSpeaker("Ghost", { storePath })).rejects.toThrow(/Ghost/);
  });
});
