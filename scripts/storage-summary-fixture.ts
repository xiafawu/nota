/**
 * The one fixture that pins the TS↔Swift storage contract (XIA-436).
 *
 * `macos/Nota/UI/Tests/Fixtures/storage-summary.json` is not hand-written. It
 * is the literal output of `nota history storage --json` over a seeded store,
 * produced here, committed, and read by both sides:
 *
 *   - the Swift `StoredStorageSummary` test decodes that file, so the app is
 *     tested against what the CLI really emits rather than against a
 *     hand-copied shape (a hand-written one had already drifted — it was
 *     missing the `status` key every real row carries);
 *   - the TS test rebuilds it through `buildStorageFixture()` and compares, so
 *     a change to the summary's shape or values fails loudly on the TS side
 *     with an instruction to regenerate rather than silently desynchronising
 *     the app.
 *
 * Regenerate with:
 *
 *   npx tsx scripts/storage-summary-fixture.ts macos/Nota/UI/Tests/Fixtures/storage-summary.json
 */
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { storageCommand } from "../src/cli/storage.js";
import { recordAssetsDir } from "../src/pipeline/storage.js";

/** Everything the contract has to carry, in one store. */
async function seedFixtureStore(dir: string): Promise<void> {
  async function seed(
    id: string,
    createdAt: string,
    audioBytes: number | null,
    clipBytes = 0,
  ): Promise<void> {
    const assets = recordAssetsDir(id, dir);
    await mkdir(assets, { recursive: true });
    if (audioBytes !== null) {
      await writeFile(path.join(assets, "recording.caf"), Buffer.alloc(audioBytes));
    }
    if (clipBytes > 0) {
      await writeFile(path.join(assets, "Speaker 1.pcm"), Buffer.alloc(clipBytes));
    }
    const record: Record<string, unknown> = {
      id,
      createdAt,
      updatedAt: createdAt,
      capturedAt: createdAt,
      // Fixed literals, never the temp directory: `recordBytes` is the JSON's
      // own size, so a path that varies per machine would make the fixture
      // unreproducible on the next one. (A legacy record's `sourcePath` points
      // at the owner's own file outside the store; a record-first one names
      // its own recording.)
      sourcePath:
        audioBytes === null
          ? "/Users/owner/Music/interview.m4a"
          : "/Users/owner/.nota/history/with-audio.assets/recording.caf",
      sourceName: "recording.caf",
      provider: "assemblyai",
      options: { diarize: true, identify: false, model: "gpt-5-mini" },
      durationMinutes: 12,
      transcriptText: "t",
      segments: [],
      status: "done",
    };
    if (audioBytes !== null) {
      record.audioPath = "recording.caf";
      record.audioBytes = audioBytes;
    }
    await writeFile(path.join(dir, `${id}.json`), JSON.stringify(record, null, 2), "utf-8");
  }

  await seed("legacy-no-audio", "2026-01-05T10:00:00.000Z", null);
  await seed("with-audio", "2026-02-01T09:30:00.000Z", 2048, 512);
  // A leftover no record names, so the contract carries an orphan row too.
  await mkdir(recordAssetsDir("orphaned", dir), { recursive: true });
  await writeFile(
    path.join(recordAssetsDir("orphaned", dir), "recording.caf"),
    Buffer.alloc(4096),
  );
}

/** The fixture's JSON, exactly as `nota history storage --json` writes it. */
export async function buildStorageFixture(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "nota-storage-fixture-"));
  await seedFixtureStore(dir);
  const lines: string[] = [];
  await storageCommand({
    historyDir: dir,
    json: true,
    out: (line) => lines.push(line),
    write: () => {},
    now: new Date("2026-02-15T00:00:00.000Z"),
  });
  return `${lines.join("\n")}\n`;
}

if (process.argv[1] && process.argv[1].endsWith("storage-summary-fixture.ts")) {
  const json = await buildStorageFixture();
  const target = process.argv[2];
  if (target) await writeFile(target, json, "utf-8");
  else process.stdout.write(json);
}
