# Captured vs Transcribed Dates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record and display two distinct timestamps per transcript — *captured* (when audio was recorded) and *transcribed* (when Nota processed it).

**Architecture:** A new `resolveCaptureDate` util reads the container's `creation_time` metadata (ffprobe) and falls back to filesystem birthtime, returning `Date | null`. The orchestrator computes it once per pipeline path and threads `capturedDate`/`transcribedDate` into the markdown writer and `capturedAt` into history.json.

**Tech Stack:** TypeScript (ESM), Node fs/child_process, ffprobe (already a dependency), vitest.

**Spec:** `docs/superpowers/specs/2026-05-21-captured-vs-transcribed-dates-design.md`

---

### Task 1: `resolveCaptureDate` utility

**Files:**
- Create: `src/utils/capture-date.ts`
- Test: `tests/utils/capture-date.test.ts`

- [ ] **Step 1: Write the failing test**

Create `tests/utils/capture-date.test.ts`:

```ts
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { resolveCaptureDate } from "../../src/utils/capture-date.js";

const execFileAsync = promisify(execFile);

describe("resolveCaptureDate", () => {
  let dir: string;
  let taggedAudio: string;
  let plainFile: string;

  beforeAll(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "nota-capture-test-"));
    taggedAudio = path.join(dir, "tagged.m4a");
    plainFile = path.join(dir, "plain.bin");

    // 1s of silence with an embedded creation_time tag.
    await execFileAsync("ffmpeg", [
      "-y",
      "-f", "lavfi",
      "-i", "anullsrc=r=8000:cl=mono",
      "-t", "1",
      "-metadata", "creation_time=2020-01-02T03:04:05.000000Z",
      taggedAudio,
    ]);

    await writeFile(plainFile, "not audio data");
  });

  afterAll(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  it("reads creation_time from container metadata", async () => {
    const date = await resolveCaptureDate(taggedAudio);
    expect(date).not.toBeNull();
    expect(date!.toISOString().split("T")[0]).toBe("2020-01-02");
  });

  it("falls back to filesystem birthtime when no metadata tag", async () => {
    const date = await resolveCaptureDate(plainFile);
    expect(date).not.toBeNull();
    expect(date!.getFullYear()).toBe(new Date().getFullYear());
  });

  it("returns null for a nonexistent file", async () => {
    const date = await resolveCaptureDate(path.join(dir, "nope.m4a"));
    expect(date).toBeNull();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/utils/capture-date.test.ts`
Expected: FAIL — cannot resolve `../../src/utils/capture-date.js` (module does not exist).

- [ ] **Step 3: Write minimal implementation**

Create `src/utils/capture-date.ts`:

```ts
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { stat } from "node:fs/promises";

const execFileAsync = promisify(execFile);

/**
 * Resolve when the audio was captured (recorded), independent of when Nota
 * processes it. Tries container metadata first (the creation_time tag survives
 * copy/AirDrop/download), then falls back to the file's on-disk birth time.
 * Returns null when neither source yields a usable date.
 */
export async function resolveCaptureDate(
  filePath: string,
): Promise<Date | null> {
  const fromMetadata = await captureFromMetadata(filePath);
  if (fromMetadata) return fromMetadata;

  const fromBirthtime = await captureFromBirthtime(filePath);
  if (fromBirthtime) return fromBirthtime;

  return null;
}

async function captureFromMetadata(filePath: string): Promise<Date | null> {
  try {
    const { stdout } = await execFileAsync("ffprobe", [
      "-v", "quiet",
      "-show_entries", "format_tags=creation_time",
      "-of", "default=nw=1:nk=1",
      filePath,
    ]);
    const value = stdout.trim();
    if (!value) return null;
    const date = new Date(value);
    return isNaN(date.getTime()) ? null : date;
  } catch {
    return null;
  }
}

async function captureFromBirthtime(filePath: string): Promise<Date | null> {
  try {
    const stats = await stat(filePath);
    const ms = stats.birthtimeMs;
    if (!ms || ms <= 0) return null;
    const date = new Date(ms);
    return isNaN(date.getTime()) ? null : date;
  } catch {
    return null;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/utils/capture-date.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/utils/capture-date.ts tests/utils/capture-date.test.ts
git commit -m "feat(capture): resolve capture date from metadata with fs fallback"
```

---

### Task 2: Persist `capturedAt` in history.json

**Files:**
- Modify: `src/pipeline/history.ts` (HistoryRecord ~19-33, CreateHistoryInput ~35-43, createHistoryRecord ~69-96)
- Test: `tests/pipeline/history.test.ts`

- [ ] **Step 1: Write the failing test**

Add this test inside the `describe("history", ...)` block in `tests/pipeline/history.test.ts`:

```ts
  it("persists capturedAt and round-trips it on read", async () => {
    const record = await createHistoryRecord(
      {
        sourcePath: "/tmp/recorded.m4a",
        provider: "assemblyai",
        options: { diarize: true, identify: false, model: "gpt-4o" },
        durationMinutes: 5,
        transcriptText: "Hi",
        segments: [],
        capturedAt: "2020-01-02T03:04:05.000Z",
      },
      historyDir,
    );
    expect(record.capturedAt).toBe("2020-01-02T03:04:05.000Z");

    const loaded = await loadHistoryRecord(record.id, historyDir);
    expect(loaded.capturedAt).toBe("2020-01-02T03:04:05.000Z");
  });

  it("stores null capturedAt when not provided", async () => {
    const record = await createHistoryRecord(
      {
        sourcePath: "/tmp/unknown.m4a",
        provider: "whisper",
        options: { diarize: false, identify: false, model: "gpt-4o" },
        durationMinutes: 1,
        transcriptText: "Hi",
        segments: [],
      },
      historyDir,
    );
    expect(record.capturedAt).toBeNull();
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/history.test.ts`
Expected: FAIL — `capturedAt` is not a property on the created record (compile error / `undefined` not `null`).

- [ ] **Step 3: Add `capturedAt` to the record interface**

In `src/pipeline/history.ts`, in `interface HistoryRecord`, add after the `updatedAt: string;` line:

```ts
  capturedAt: string | null;
```

- [ ] **Step 4: Add `capturedAt` to the create input**

In `interface CreateHistoryInput`, add after `segments: TranscriptSegment[];`:

```ts
  capturedAt?: string | null;
```

- [ ] **Step 5: Write `capturedAt` in createHistoryRecord**

In `createHistoryRecord`, in the `const record: HistoryRecord = {` literal, add after `updatedAt: now,`:

```ts
    capturedAt: input.capturedAt ?? null,
```

- [ ] **Step 6: Run test to verify it passes**

Run: `npx vitest run tests/pipeline/history.test.ts`
Expected: PASS (all history tests, including the two new ones).

- [ ] **Step 7: Commit**

```bash
git add src/pipeline/history.ts tests/pipeline/history.test.ts
git commit -m "feat(history): persist capturedAt timestamp"
```

---

### Task 3: Split markdown header into Captured + Transcribed

**Files:**
- Modify: `src/pipeline/write.ts` (WriteInput ~7-13, buildMarkdown ~15-36)
- Test: `tests/pipeline/write.test.ts`

- [ ] **Step 1: Update existing tests and add the null case**

In `tests/pipeline/write.test.ts`, in the FIRST test ("produces valid markdown..."), replace the `date: "2026-03-10",` line in the `buildMarkdown({...})` call with:

```ts
      capturedDate: "2026-03-08",
      transcribedDate: "2026-03-10",
```

and replace the assertion `expect(md).toContain("**Date:** 2026-03-10");` with:

```ts
    expect(md).toContain("**Captured:** 2026-03-08");
    expect(md).toContain("**Transcribed:** 2026-03-10");
```

In the SECOND test ("includes speaker labels..."), replace `date: "2026-03-10",` with:

```ts
      capturedDate: "2026-03-10",
      transcribedDate: "2026-03-10",
```

Then add a THIRD test inside the `describe` block:

```ts
  it("renders an em dash when captured date is unknown", () => {
    const summary: MeetingSummary = {
      narrative: "x",
      keyTopics: [],
      decisions: [],
      actionItems: [],
    };
    const md = buildMarkdown({
      summary,
      segments: [],
      capturedDate: null,
      transcribedDate: "2026-03-10",
      duration: 5,
      source: "a.mp3",
    });
    expect(md).toContain("**Captured:** —");
    expect(md).toContain("**Transcribed:** 2026-03-10");
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/write.test.ts`
Expected: FAIL — `WriteInput` has no `capturedDate`/`transcribedDate` (type error) and output still says `**Date:**`.

- [ ] **Step 3: Update the WriteInput interface**

In `src/pipeline/write.ts`, replace the `date: string;` line in `interface WriteInput` with:

```ts
  capturedDate: string | null;
  transcribedDate: string;
```

- [ ] **Step 4: Update buildMarkdown destructure and header**

In `buildMarkdown`, replace the destructure line:

```ts
  const { summary, segments, date, duration, source } = input;
```

with:

```ts
  const { summary, segments, capturedDate, transcribedDate, duration, source } =
    input;
```

Then in the returned template string, replace the line `**Date:** ${date}` with:

```ts
**Captured:** ${capturedDate ?? "—"}
**Transcribed:** ${transcribedDate}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run tests/pipeline/write.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add src/pipeline/write.ts tests/pipeline/write.test.ts
git commit -m "feat(write): split header into Captured and Transcribed dates"
```

---

### Task 4: Wire capture date into both orchestrator pipelines

**Files:**
- Modify: `src/orchestrator.ts` (import ~15-16; assemblyai inner ~159-197; whisper ~358-401)

- [ ] **Step 1: Import the resolver**

In `src/orchestrator.ts`, after the line `import { getAudioDuration } from "./utils/ffmpeg.js";`, add:

```ts
import { resolveCaptureDate } from "./utils/capture-date.js";
```

- [ ] **Step 2: AssemblyAI path — compute capturedAt before history**

In `runAssemblyAIPipelineInner`, the block currently reads (around the speaker-identify section, just before the history block):

```ts
  // 2b. Identify speakers by voice (if enabled)
  let segments = result.segments;
  if (config.identify) {
    const audioForEmbeddings = localAudioPath ?? inputPath;
    segments = await identifySpeakers(audioForEmbeddings, segments, verbose);
  }

  // 2c. Save transcript history before summarization so the transcript survives
```

Insert a capture-date line between the identify block and the `// 2c.` comment:

```ts
  // 2b. Identify speakers by voice (if enabled)
  let segments = result.segments;
  if (config.identify) {
    const audioForEmbeddings = localAudioPath ?? inputPath;
    segments = await identifySpeakers(audioForEmbeddings, segments, verbose);
  }

  const capturedAt = await resolveCaptureDate(inputPath);

  // 2c. Save transcript history before summarization so the transcript survives
```

- [ ] **Step 3: AssemblyAI path — pass capturedAt to history**

In the same function, in the `createHistoryRecord({...})` call, add after the `outputPath,` line:

```ts
      capturedAt: capturedAt ? capturedAt.toISOString() : null,
```

- [ ] **Step 4: AssemblyAI path — replace the write date logic**

Replace this block:

```ts
  const date = new Date().toISOString().split("T")[0];
  const source = path.basename(inputPath);

  await writeOutput(
    { summary, segments, date, duration: durationMinutes, source },
    outputPath,
  );
```

with:

```ts
  const transcribedDate = new Date().toISOString().split("T")[0];
  const capturedDate = capturedAt
    ? capturedAt.toISOString().split("T")[0]
    : null;
  const source = path.basename(inputPath);

  await writeOutput(
    {
      summary,
      segments,
      capturedDate,
      transcribedDate,
      duration: durationMinutes,
      source,
    },
    outputPath,
  );
```

- [ ] **Step 5: Whisper path — compute capturedAt before history**

In `runWhisperPipeline`, the align block ends just before the history block:

```ts
  // 4c. Save transcript history before summarization so the transcript survives
  //     even if the GPT summary step fails.
  let historyId: string | undefined;
```

Insert the capture-date line before the `// 4c.` comment:

```ts
  const capturedAt = await resolveCaptureDate(inputPath);

  // 4c. Save transcript history before summarization so the transcript survives
  //     even if the GPT summary step fails.
  let historyId: string | undefined;
```

- [ ] **Step 6: Whisper path — pass capturedAt to history**

In `runWhisperPipeline`'s `createHistoryRecord({...})` call, add after the `outputPath,` line:

```ts
      capturedAt: capturedAt ? capturedAt.toISOString() : null,
```

- [ ] **Step 7: Whisper path — replace the write date logic**

Replace this block:

```ts
  const date = new Date().toISOString().split("T")[0];
  const source = path.basename(inputPath);

  await writeOutput(
    {
      summary,
      segments: merged.segments,
      date,
      duration: durationMinutes,
      source,
    },
    outputPath,
  );
```

with:

```ts
  const transcribedDate = new Date().toISOString().split("T")[0];
  const capturedDate = capturedAt
    ? capturedAt.toISOString().split("T")[0]
    : null;
  const source = path.basename(inputPath);

  await writeOutput(
    {
      summary,
      segments: merged.segments,
      capturedDate,
      transcribedDate,
      duration: durationMinutes,
      source,
    },
    outputPath,
  );
```

- [ ] **Step 8: Typecheck + full suite**

Run: `npm run build && npm test`
Expected: build succeeds (no TS errors), all tests pass. If `orchestrator.test.ts` references the old `date` field or asserts `**Date:**`, update those references to the new fields/labels the same way as Task 3.

- [ ] **Step 9: Commit**

```bash
git add src/orchestrator.ts
git commit -m "feat(orchestrator): wire captured date into both pipelines"
```

---

### Task 5: Update docs

**Files:**
- Modify: `CLAUDE.md` (Architecture → write.ts bullet, and/or a brief note on the two dates)

- [ ] **Step 1: Note the dual dates in CLAUDE.md**

In `CLAUDE.md`, under the `src/pipeline/` list, change the `write.ts` bullet to:

```md
  - `write.ts` — generates markdown output file; header carries **Captured** (recording time from container metadata, fs-birthtime fallback) and **Transcribed** (processing time) dates
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: note captured vs transcribed dates in architecture"
```

---

## Self-Review

**Spec coverage:**
- Captured source = metadata → birthtime → null → Task 1 ✔
- Always-both display, `—` when unknown → Task 3 ✔
- Markdown header → Task 3 ✔; history.json `capturedAt` → Task 2 ✔; wired both pipelines → Task 4 ✔
- macOS app untouched (data only) → no task touches `macos/` ✔
- UTC behavior consistent with existing transcribed date → Task 4 uses `.toISOString()` like the original ✔

**Type consistency:**
- `resolveCaptureDate(filePath: string): Promise<Date | null>` — defined Task 1, called Task 4 ✔
- `WriteInput.capturedDate: string | null`, `transcribedDate: string` — defined Task 3, supplied Task 4 ✔
- `CreateHistoryInput.capturedAt?: string | null`, `HistoryRecord.capturedAt: string | null` — defined Task 2, supplied Task 4 ✔
- ISO string (`toISOString()`) → history; date-only (`split("T")[0]`) → markdown — consistent across both Task 4 paths ✔

**Placeholder scan:** none — every code step shows full content.
