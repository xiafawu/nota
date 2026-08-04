import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  deleteSpeaker,
  doctorSpeakers,
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

const EMBEDDING = [1, 0, 0, 0];

function writeStore(store: SpeakerStore): void {
  writeFileSync(storePath, JSON.stringify(store), "utf-8");
}

function readStore(): SpeakerStore {
  return JSON.parse(readFileSync(storePath, "utf-8")) as SpeakerStore;
}

function vp(id: string, source = "demo.mp3", embedding = EMBEDDING): Voiceprint {
  return { id, embedding, enrolledAt: id, source };
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

  it("prints one tab-separated row per voiceprint with embedding dimension", async () => {
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
    expect(bytes).toBe("4");

    expect(lines[1].split("\t")[1]).toBe("2026-02-15T00:00:00.000Z");
  });

  it("drops legacy Eagle profile records on load", async () => {
    writeFileSync(
      storePath,
      JSON.stringify({
        version: 3,
        speakers: {
          Alice: {
            voiceprints: [
              { id: "x", profile: "AQIDBA==", enrolledAt: "x", source: "legacy.mp3" },
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
    expect(after.speakers.Alicia.voiceprints[0].embedding).toEqual(EMBEDDING);
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
    expect(first?.embedding).toEqual(EMBEDDING);
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
  it("prints a JSON view with the embedding dimension per voiceprint", async () => {
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
    expect(parsed.voiceprints[0].embeddingDimension).toBe(4);
    expect(parsed.voiceprints[0].id).toBe("2026-01-01T00:00:00.000Z");
  });

  it("throws when the speaker is missing", async () => {
    writeStore({ version: 3, speakers: {} });
    await expect(showSpeaker("Ghost", { storePath })).rejects.toThrow(/Ghost/);
  });

  it("surfaces the lowAgreement flag on a voiceprint", async () => {
    writeStore({
      version: 4,
      speakers: {
        Brian: {
          voiceprints: [
            { ...vp("2026-07-14T00:00:00.000Z"), lowAgreement: true },
          ],
        },
      },
    });

    await showSpeaker("Brian", { storePath });
    const parsed = JSON.parse(stdoutChunks.join(""));
    expect(parsed.voiceprints[0].lowAgreement).toBe(true);
  });
});

describe("doctorSpeakers", () => {
  it("reports a healthy store with no stdout rows", async () => {
    writeStore({
      version: 4,
      speakers: {
        Alice: { voiceprints: [vp("2026-01-01T00:00:00.000Z")] },
      },
    });

    await doctorSpeakers({ storePath });
    expect(stdoutChunks.join("")).toBe("");
    expect(stderrChunks.join("")).toContain("Store looks healthy");
  });

  it("lists flagged low-agreement voiceprints with their best same-name score", async () => {
    // Brian's two enrollments disagree at 0.025 (the research-doc pair).
    writeStore({
      version: 4,
      speakers: {
        Brian: {
          voiceprints: [
            vp("2026-07-14T00:00:00.000Z", "a.m4a", [1, 0, 0, 0]),
            {
              ...vp("2026-07-21T00:00:00.000Z", "b.m4a", [0.025, 0.9997, 0, 0]),
              lowAgreement: true,
            },
          ],
        },
      },
    });

    await doctorSpeakers({ storePath });

    const out = stdoutChunks.join("");
    expect(out).toContain(
      "Brian\t2026-07-21T00:00:00.000Z\t0.025",
    );
    expect(stderrChunks.join("")).toContain("Low-agreement voiceprints");
  });

  it("lists same-name pairs below 0.30 even when unflagged (legacy garbage)", async () => {
    writeStore({
      version: 4,
      speakers: {
        Brian: {
          voiceprints: [
            // v1 healthy, v2 garbage (0.1 from v1, no flag — legacy), v3
            // healthy and agreeing with v1 at 0.95.
            vp("2026-07-14T00:00:00.000Z", "a.m4a", [1, 0, 0, 0]),
            vp("2026-07-21T00:00:00.000Z", "b.m4a", [0.1, 0.995, 0, 0]),
            vp("2026-07-28T00:00:00.000Z", "c.m4a", [0.95, 0.312, 0, 0]),
          ],
        },
      },
    });

    await doctorSpeakers({ storePath });

    const out = stdoutChunks.join("");
    // Only the (v1, v2) pair is below 0.30; (v1, v3) = 0.95 and
    // (v2, v3) = 0.405 are healthy and must not appear.
    expect(out).toContain("Brian\t2026-07-14T00:00:00.000Z\t2026-07-21T00:00:00.000Z\t0.100");
    expect(out).not.toContain("2026-07-28");
    expect(stderrChunks.join("")).toContain("below 0.30");
  });
});
