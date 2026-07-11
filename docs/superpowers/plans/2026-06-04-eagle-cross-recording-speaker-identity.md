# Eagle Cross-Recording Speaker Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make naming a speaker once cause that speaker to be auto-recognized in future recordings, using on-device Picovoice Eagle and embeddings captured during the pipeline run.

**Architecture:** During a run (audio still present) we decode the input to 16 kHz mono PCM, recognize already-enrolled speakers via Eagle, and persist a short per-speaker PCM clip under `~/.nota/history/<id>.assets/`. Later, naming a speaker in the viewer (or `nota enroll`) builds an Eagle profile from that stored clip — no original audio needed. The voiceprint store moves from pyannote float vectors to base64 Eagle profile blobs (schema v3).

**Tech Stack:** TypeScript (ESM), `@picovoice/eagle-node`, ffmpeg (raw `s16le` decode), vitest.

**Spec:** `docs/superpowers/specs/2026-06-04-eagle-cross-recording-speaker-identity-design.md`

**Eagle API contract (verified against binding source):**
- `new EagleProfiler(accessKey, { minEnrollmentChunks? })`; getters `.frameLength`, `.sampleRate`; `enroll(pcm: Int16Array): number` (pcm.length **must equal** `.frameLength`, returns 0–100); `flush(): number`; `export(): Uint8Array`; `release()`.
- `new Eagle(accessKey)`; getters `.minProcessSamples`, `.sampleRate`; `process(pcm: Int16Array, profiles: Uint8Array[]): number[]` (pcm.length **must be ≥** `.minProcessSamples`, returns one score 0–1 per profile, in order); `release()`.
- A profile IS a raw `Uint8Array`. Store base64; pass the decoded `Uint8Array` back to `process()`. No `fromBytes`.

---

## File Structure

- Create `src/utils/pcm.ts` — ffmpeg decode to `Int16Array` (16 kHz mono s16le); slice PCM by utterance time ranges; concat-to-target-seconds; frame/chunk iterators.
- Create `src/pipeline/eagle.ts` — Eagle wrapper: `isEagleAvailable`, `enrollProfile(pcm)`, `recognize(pcmByLabel, profiles)`; thresholds.
- Modify `src/config.ts` — add `picovoiceAccessKey?` from `PICOVOICE_ACCESS_KEY`.
- Modify `src/pipeline/speakers.ts` — schema v3 (`profile: string` base64 instead of `embedding: number[]`); drop v2 `embedding` records on load; remove pyannote `extractEmbeddings` + cosine matching from the identity path; keep `applySpeakerNames`, `promptForSpeakerNames`.
- Modify `src/pipeline/history.ts` — add `speakerClips?: Record<string,string>`; `writeSpeakerClip()` helper writing `<id>.assets/<label>.pcm`.
- Modify `src/orchestrator.ts` — rewrite `identifySpeakers` to use PCM + Eagle + clip capture.
- Modify `src/cli/enroll.ts` — enroll from the stored clip via Eagle; new exit code 5 (insufficient speech).
- Modify `CLAUDE.md` — document Eagle backend + `PICOVOICE_ACCESS_KEY` + capture-during-run.

Dependency order: Task 1 (pcm) → 2 (eagle) → 3 (config) → 4 (store v3) → 5 (history clips) → 6 (orchestrator) → 7 (enroll) → 8 (docs/cleanup).

---

## Task 0: Install dependency

- [ ] **Step 1: Add the Eagle Node SDK**

Run: `npm install @picovoice/eagle-node`
Expected: package added to `dependencies` in `package.json`; `npm ls @picovoice/eagle-node` shows a version.

- [ ] **Step 2: Commit**

```bash
git add package.json package-lock.json
git commit -m "chore(deps): add @picovoice/eagle-node for on-device speaker recognition"
```

---

## Task 1: PCM utilities (`src/utils/pcm.ts`)

**Files:**
- Create: `src/utils/pcm.ts`
- Test: `tests/utils/pcm.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
import { mkdtemp, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { decodePcm, slicePcm, concatToSeconds, SAMPLE_RATE } from "../../src/utils/pcm.js";

const execFileAsync = promisify(execFile);

describe("pcm utils", () => {
  let dir: string;
  let wav: string;

  beforeEach(async () => {
    dir = await mkdtemp(path.join(tmpdir(), "nota-pcm-test-"));
    wav = path.join(dir, "tone.wav");
    // 2s 440Hz sine, 16kHz mono — deterministic fixture, no binary committed.
    await execFileAsync("ffmpeg", ["-y", "-f", "lavfi", "-i",
      "sine=frequency=440:duration=2", "-ar", String(SAMPLE_RATE), "-ac", "1", wav]);
  });
  afterEach(async () => { await rm(dir, { recursive: true, force: true }); });

  it("decodes a wav to ~32000 samples at 16kHz mono", async () => {
    const pcm = await decodePcm(wav);
    expect(pcm).toBeInstanceOf(Int16Array);
    // 2s * 16000 ≈ 32000 samples, allow small encoder slack.
    expect(pcm.length).toBeGreaterThan(31000);
    expect(pcm.length).toBeLessThan(33000);
  });

  it("slices PCM by time ranges (seconds → samples)", async () => {
    const pcm = await decodePcm(wav);
    const slice = slicePcm(pcm, [{ start: 0.5, end: 1.0 }]);
    // 0.5s at 16kHz = 8000 samples.
    expect(slice.length).toBeGreaterThan(7500);
    expect(slice.length).toBeLessThan(8500);
  });

  it("concatToSeconds trims to the target length", async () => {
    const pcm = await decodePcm(wav);
    const out = concatToSeconds([pcm, pcm], 1); // request 1s out of 4s available
    expect(out.length).toBe(SAMPLE_RATE); // exactly 16000 samples
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/utils/pcm.test.ts`
Expected: FAIL — cannot find module `src/utils/pcm.js`.

- [ ] **Step 3: Write the implementation**

```typescript
// src/utils/pcm.ts
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** Eagle operates on 16 kHz, mono, 16-bit signed little-endian PCM. */
export const SAMPLE_RATE = 16000;

/**
 * Decode any ffmpeg-readable audio file to a mono 16 kHz Int16Array.
 * Streams raw `s16le` on stdout so we never write a temp WAV.
 */
export async function decodePcm(inputPath: string): Promise<Int16Array> {
  const { stdout } = await execFileAsync(
    "ffmpeg",
    ["-v", "quiet", "-i", inputPath, "-f", "s16le", "-acodec", "pcm_s16le",
     "- ar", String(SAMPLE_RATE), "-ac", "1", "-"].flatMap((a) => a.split(" ")),
    { encoding: "buffer", maxBuffer: 1024 * 1024 * 512 },
  );
  const buf = stdout as unknown as Buffer;
  // Reinterpret the byte buffer as Int16 samples (little-endian on all
  // supported platforms). Copy to a fresh Int16Array aligned at offset 0.
  return new Int16Array(buf.buffer, buf.byteOffset, Math.floor(buf.length / 2));
}

export interface TimeRange { start: number; end: number; }

/** Concatenate the PCM sample windows covered by the given time ranges. */
export function slicePcm(pcm: Int16Array, ranges: TimeRange[]): Int16Array {
  const parts: Int16Array[] = [];
  let total = 0;
  for (const { start, end } of ranges) {
    const s = Math.max(0, Math.floor(start * SAMPLE_RATE));
    const e = Math.min(pcm.length, Math.floor(end * SAMPLE_RATE));
    if (e > s) { const part = pcm.subarray(s, e); parts.push(part); total += part.length; }
  }
  const out = new Int16Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

/** Concatenate chunks and trim to `seconds` (or return all if shorter). */
export function concatToSeconds(chunks: Int16Array[], seconds: number): Int16Array {
  const target = Math.floor(seconds * SAMPLE_RATE);
  const out = new Int16Array(target);
  let off = 0;
  for (const c of chunks) {
    if (off >= target) break;
    const take = Math.min(c.length, target - off);
    out.set(c.subarray(0, take), off);
    off += take;
  }
  return off === target ? out : out.subarray(0, off);
}

/** Yield fixed-size frames (drops a trailing partial frame). */
export function* frames(pcm: Int16Array, frameLength: number): Generator<Int16Array> {
  for (let i = 0; i + frameLength <= pcm.length; i += frameLength) {
    yield pcm.subarray(i, i + frameLength);
  }
}
```

> NOTE on Step 3: the `-ar` flag is split correctly by the real implementation — write it as a normal arg array. The `.flatMap(split)` above is illustrative only; in the actual file use a plain array: `["-v","quiet","-i",inputPath,"-f","s16le","-acodec","pcm_s16le","-ar",String(SAMPLE_RATE),"-ac","1","-"]`. Use the plain array.

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/utils/pcm.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/utils/pcm.ts tests/utils/pcm.test.ts
git commit -m "feat(pcm): ffmpeg decode to 16kHz mono Int16 PCM + slice/concat helpers"
```

---

## Task 2: Eagle wrapper (`src/pipeline/eagle.ts`)

**Files:**
- Create: `src/pipeline/eagle.ts`
- Test: `tests/pipeline/eagle.test.ts`

- [ ] **Step 1: Write the failing test** (gated on AccessKey; skips cleanly in CI without one)

```typescript
import { mkdtemp, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { tmpdir } from "node:os";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { decodePcm } from "../../src/utils/pcm.js";
import { isEagleAvailable, enrollProfile, recognize, InsufficientSpeechError } from "../../src/pipeline/eagle.js";

const execFileAsync = promisify(execFile);
const KEY = process.env.PICOVOICE_ACCESS_KEY;

describe("eagle", () => {
  it("isEagleAvailable reflects the AccessKey", () => {
    expect(isEagleAvailable(KEY)).toBe(Boolean(KEY));
  });

  it.skipIf(!KEY)("enrolls from speech PCM and recognizes the same voice high", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "nota-eagle-test-"));
    try {
      // ~25s of speech-like audio. (For a real fixture use a short spoken wav;
      // a tone may not enroll — see Step 4 note.)
      const wav = path.join(dir, "spk.wav");
      await execFileAsync("ffmpeg", ["-y", "-f", "lavfi", "-i",
        "sine=frequency=180:duration=25", "-ar", "16000", "-ac", "1", wav]);
      const pcm = await decodePcm(wav);
      const profile = await enrollProfile(KEY!, pcm);
      expect(profile).toBeInstanceOf(Uint8Array);
      expect(profile.length).toBeGreaterThan(0);

      const scores = recognize(KEY!, { "Speaker 1": pcm }, [profile]);
      expect(scores["Speaker 1"].index).toBe(0);
      expect(scores["Speaker 1"].score).toBeGreaterThan(0.5);
    } finally { await rm(dir, { recursive: true, force: true }); }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/eagle.test.ts`
Expected: FAIL — cannot find module `src/pipeline/eagle.js`.

- [ ] **Step 3: Write the implementation**

```typescript
// src/pipeline/eagle.ts
import { EagleProfiler, Eagle } from "@picovoice/eagle-node";
import { frames } from "../utils/pcm.js";

/** Auto-assign a name at/above this Eagle score; prompt in the band below. */
export const MATCH_THRESHOLD = 0.6;
export const TENTATIVE_THRESHOLD = 0.4;

export class InsufficientSpeechError extends Error {
  constructor() { super("Not enough speech to enroll a voice profile"); this.name = "InsufficientSpeechError"; }
}

export function isEagleAvailable(accessKey?: string): boolean {
  return Boolean(accessKey && accessKey.trim());
}

/**
 * Build an Eagle speaker profile from a speaker's PCM. Feeds frame-sized
 * windows until enrollment reaches 100%, then flush + export. Throws
 * InsufficientSpeechError if 100% is never reached (too little clean speech).
 */
export async function enrollProfile(accessKey: string, pcm: Int16Array): Promise<Uint8Array> {
  const profiler = new EagleProfiler(accessKey);
  try {
    let percent = 0;
    for (const frame of frames(pcm, profiler.frameLength)) {
      percent = profiler.enroll(frame);
      if (percent >= 100) break;
    }
    if (percent < 100) percent = profiler.flush();
    if (percent < 100) throw new InsufficientSpeechError();
    return profiler.export();
  } finally {
    profiler.release();
  }
}

/**
 * Score each label's PCM against a flat list of enrolled profiles. Feeds
 * chunks of >= minProcessSamples and means the per-profile scores, then
 * returns the best { index, score } per label. `index` points into `profiles`.
 */
export function recognize(
  accessKey: string,
  pcmByLabel: Record<string, Int16Array>,
  profiles: Uint8Array[],
): Record<string, { index: number; score: number }> {
  const out: Record<string, { index: number; score: number }> = {};
  if (profiles.length === 0) return out;
  const eagle = new Eagle(accessKey);
  try {
    const chunk = eagle.minProcessSamples;
    for (const [label, pcm] of Object.entries(pcmByLabel)) {
      const sums = new Array(profiles.length).fill(0);
      let n = 0;
      for (let i = 0; i + chunk <= pcm.length; i += chunk) {
        const scores = eagle.process(pcm.subarray(i, i + chunk), profiles);
        if (!scores) continue;
        for (let p = 0; p < profiles.length; p++) sums[p] += scores[p];
        n++;
      }
      if (n === 0) continue;
      let bestIdx = 0, best = -Infinity;
      for (let p = 0; p < profiles.length; p++) {
        const mean = sums[p] / n;
        if (mean > best) { best = mean; bestIdx = p; }
      }
      out[label] = { index: bestIdx, score: best };
    }
    return out;
  } finally {
    eagle.release();
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `PICOVOICE_ACCESS_KEY=<key> npx vitest run tests/pipeline/eagle.test.ts`
Expected: PASS (skips the enroll test if no key).
Note: a pure sine may not satisfy Eagle's voice detector; if the gated test cannot enroll, replace the fixture with a short committed spoken-word `tests/fixtures/voice.wav` and adjust the test to use it. Document the choice in the commit.

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/eagle.ts tests/pipeline/eagle.test.ts
git commit -m "feat(eagle): on-device enroll + recognize wrapper over @picovoice/eagle-node"
```

---

## Task 3: Config — AccessKey (`src/config.ts`)

**Files:**
- Modify: `src/config.ts`
- Test: `tests/config.test.ts`

- [ ] **Step 1: Write the failing test** (append inside `describe("loadConfig")`)

```typescript
  it("reads PICOVOICE_ACCESS_KEY into config", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    process.env.PICOVOICE_ACCESS_KEY = "pv-test";
    expect(loadConfig({}).picovoiceAccessKey).toBe("pv-test");
  });

  it("leaves picovoiceAccessKey undefined when unset", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ASSEMBLYAI_API_KEY = "aai-test";
    delete process.env.PICOVOICE_ACCESS_KEY;
    expect(loadConfig({}).picovoiceAccessKey).toBeUndefined();
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/config.test.ts`
Expected: FAIL — `picovoiceAccessKey` does not exist on `AppConfig`.

- [ ] **Step 3: Write the implementation**

In `src/config.ts`, add to `AppConfig`:
```typescript
  /** Picovoice AccessKey for on-device Eagle speaker recognition (identity). */
  picovoiceAccessKey?: string;
```
And in the returned object inside `loadConfig`:
```typescript
    picovoiceAccessKey: process.env.PICOVOICE_ACCESS_KEY,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/config.test.ts`
Expected: PASS (all config tests).

- [ ] **Step 5: Commit**

```bash
git add src/config.ts tests/config.test.ts
git commit -m "feat(config): read PICOVOICE_ACCESS_KEY for Eagle speaker identity"
```

---

## Task 4: Store schema v3 (`src/pipeline/speakers.ts`)

**Files:**
- Modify: `src/pipeline/speakers.ts`
- Test: `tests/pipeline/speakers.test.ts`

Change the voiceprint payload from `embedding: number[]` to `profile: string` (base64 Eagle profile). Bump `STORE_VERSION` to 3. On load, drop any record carrying the old `embedding` shape (cannot convert pyannote → Eagle) with a one-line stderr note. Remove `extractEmbeddings`, `cosineSimilarity`, `clusterLabels`, and `matchSpeakers` from the identity path (they are pyannote-vector specific). Add `decodeProfile`/`encodeProfile` helpers and a `matchProfiles` that delegates to `eagle.recognize`.

- [ ] **Step 1: Write the failing test**

```typescript
// add to tests/pipeline/speakers.test.ts
import { loadProfiles, saveProfiles, encodeProfile, decodeProfile, type SpeakerStore } from "../../src/pipeline/speakers.js";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";

describe("speaker store v3", () => {
  let file: string;
  beforeEach(async () => { file = path.join(await mkdtemp(path.join(tmpdir(), "nota-spk-")), "speakers.json"); });
  afterEach(async () => { await rm(path.dirname(file), { recursive: true, force: true }); });

  it("round-trips a v3 profile blob", async () => {
    const bytes = new Uint8Array([1, 2, 3, 4]);
    const store: SpeakerStore = { version: 3, speakers: {
      Alice: { voiceprints: [{ id: "t", profile: encodeProfile(bytes), enrolledAt: "t", source: "a.m4a" }] } } };
    await saveProfiles(store, file);
    const loaded = await loadProfiles(file);
    expect(loaded.version).toBe(3);
    expect(Array.from(decodeProfile(loaded.speakers.Alice.voiceprints[0].profile))).toEqual([1, 2, 3, 4]);
  });

  it("drops legacy embedding records on load", async () => {
    await writeFile(file, JSON.stringify({ version: 2, speakers: {
      Bob: { voiceprints: [{ id: "t", embedding: [0.1, 0.2], enrolledAt: "t", source: "b.m4a" }] } } }));
    const loaded = await loadProfiles(file);
    expect(loaded.speakers.Bob).toBeUndefined();
    expect(loaded.version).toBe(3);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/speakers.test.ts`
Expected: FAIL — `encodeProfile`/`decodeProfile` undefined; `Voiceprint.profile` missing.

- [ ] **Step 3: Write the implementation**

Replace the `Voiceprint`/store types and migration with:
```typescript
export interface Voiceprint {
  /** ISO timestamp of enrollment — also a stable CLI handle. */
  id: string;
  /** base64-encoded Eagle speaker profile (Uint8Array bytes). */
  profile: string;
  enrolledAt: string;
  source: string;
}
export interface SpeakerProfile { voiceprints: Voiceprint[]; }
export interface SpeakerStore { version: number; speakers: Record<string, SpeakerProfile>; }

const STORE_VERSION = 3;

export const encodeProfile = (bytes: Uint8Array): string => Buffer.from(bytes).toString("base64");
export const decodeProfile = (b64: string): Uint8Array => new Uint8Array(Buffer.from(b64, "base64"));
```
Rewrite `loadProfiles` to keep only v3-shaped records:
```typescript
export async function loadProfiles(filePath: string = SPEAKERS_FILE): Promise<SpeakerStore> {
  const read = async (p: string) => JSON.parse(await readFile(p, "utf-8"));
  let raw: any;
  try { raw = await read(filePath); }
  catch {
    if (filePath === SPEAKERS_FILE) { try { raw = await read(LEGACY_SPEAKERS_FILE); } catch { raw = null; } }
  }
  if (!raw || typeof raw !== "object") return { version: STORE_VERSION, speakers: {} };
  const speakers: Record<string, SpeakerProfile> = {};
  let dropped = 0;
  for (const [name, profile] of Object.entries((raw.speakers ?? {}) as Record<string, any>)) {
    const vps = (profile?.voiceprints ?? []).filter((vp: any) => typeof vp?.profile === "string");
    if (vps.length === 0) { dropped++; continue; } // legacy embedding-only record
    speakers[name] = { voiceprints: vps };
  }
  if (dropped > 0) process.stderr.write(
    `Note: dropped ${dropped} legacy pyannote speaker profile(s); re-enroll with Eagle.\n`);
  return { version: STORE_VERSION, speakers };
}
```
Delete `extractEmbeddings`, `convertForEmbedding`, `cosineSimilarity`, `clusterLabels`, `matchSpeakers`, `migrate*`, and the pyannote imports/constants (`SCRIPT_PATH`, `PYTHON_BIN`, `spawn`, `SIMILARITY_THRESHOLD`, `LOW_CONFIDENCE`, `MERGE_THRESHOLD`, `MatchResult`). Keep `loadProfiles`, `saveProfiles`, `promptForSpeakerNames`, `applySpeakerNames`, `TentativeMatch`, `PromptResult`, `DEFAULT_SPEAKERS_FILE`, `DEFAULT_LEGACY_SPEAKERS_FILE`. Add `matchProfiles`:
```typescript
import { recognize, MATCH_THRESHOLD, TENTATIVE_THRESHOLD } from "./eagle.js";
export type MatchResult = { name: string; confidence: number; tentative?: boolean };

/** Map diarized labels → enrolled names via Eagle recognition over PCM. */
export function matchProfiles(
  accessKey: string,
  pcmByLabel: Record<string, Int16Array>,
  store: SpeakerStore,
): Record<string, MatchResult> {
  const flat: { name: string; bytes: Uint8Array }[] = [];
  for (const [name, p] of Object.entries(store.speakers))
    for (const vp of p.voiceprints) flat.push({ name, bytes: decodeProfile(vp.profile) });
  if (flat.length === 0) return {};
  const scored = recognize(accessKey, pcmByLabel, flat.map((f) => f.bytes));
  const out: Record<string, MatchResult> = {};
  const claimed = new Set<string>();
  const ranked = Object.entries(scored).sort((a, b) => b[1].score - a[1].score);
  for (const [label, { index, score }] of ranked) {
    if (score < TENTATIVE_THRESHOLD) continue;
    const name = flat[index].name;
    if (claimed.has(name)) continue;
    out[label] = score >= MATCH_THRESHOLD ? { name, confidence: score } : { name, confidence: score, tentative: true };
    claimed.add(name);
  }
  return out;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/speakers.test.ts`
Expected: PASS. (Delete/replace any existing tests that referenced removed `cosineSimilarity`/`clusterLabels`/`matchSpeakers`/`extractEmbeddings`; re-point them at `matchProfiles` or remove if pyannote-specific. List removed tests in the commit body.)

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/speakers.ts tests/pipeline/speakers.test.ts
git commit -m "feat(speakers): store v3 (base64 Eagle profiles); drop pyannote embedding path"
```

---

## Task 5: History clips (`src/pipeline/history.ts`)

**Files:**
- Modify: `src/pipeline/history.ts`
- Test: `tests/pipeline/history.test.ts`

- [ ] **Step 1: Write the failing test**

```typescript
import { writeSpeakerClip, speakerClipPath } from "../../src/pipeline/history.js";
import { readFile } from "node:fs/promises";

it("writes a per-speaker clip under <id>.assets and returns a relative pointer", async () => {
  const rel = await writeSpeakerClip("20260604-000000Z-abcd1234", "Speaker 1",
    new Int16Array([1, 2, 3]), historyDir);
  expect(rel).toBe("20260604-000000Z-abcd1234.assets/Speaker 1.pcm");
  const abs = speakerClipPath("20260604-000000Z-abcd1234", "Speaker 1", historyDir);
  const buf = await readFile(abs);
  expect(buf.length).toBe(6); // 3 Int16 samples = 6 bytes
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/history.test.ts`
Expected: FAIL — `writeSpeakerClip`/`speakerClipPath` undefined.

- [ ] **Step 3: Write the implementation**

Add to `HistoryRecord` and `CreateHistoryInput`:
```typescript
  /** label → path (relative to historyDir) of the captured PCM clip. */
  speakerClips?: Record<string, string>;
```
Store `speakerClips: input.speakerClips` in `createHistoryRecord`. Add helpers:
```typescript
import { mkdir as mkdirp } from "node:fs/promises"; // if not already imported

export function speakerClipPath(id: string, label: string, historyDir = DEFAULT_HISTORY_DIR): string {
  return path.join(historyDir, `${id}.assets`, `${label}.pcm`);
}

/** Persist a speaker's PCM clip; returns its path relative to historyDir. */
export async function writeSpeakerClip(
  id: string, label: string, pcm: Int16Array, historyDir = DEFAULT_HISTORY_DIR,
): Promise<string> {
  const abs = speakerClipPath(id, label, historyDir);
  await mkdir(path.dirname(abs), { recursive: true });
  await writeFile(abs, Buffer.from(pcm.buffer, pcm.byteOffset, pcm.byteLength));
  return path.relative(historyDir, abs);
}
```
(`mkdir`/`writeFile` are already imported from `node:fs/promises` at the top of the file.)

- [ ] **Step 4: Run test to verify it passes**

Run: `npx vitest run tests/pipeline/history.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/history.ts tests/pipeline/history.test.ts
git commit -m "feat(history): persist per-speaker PCM clips under <id>.assets for later enroll"
```

---

## Task 6: Orchestrator — recognize + capture (`src/orchestrator.ts`)

**Files:**
- Modify: `src/orchestrator.ts` (`identifySpeakers` and its two call sites)
- Test: covered indirectly; add a unit test for the pure clip-selection helper.

Rewrite `identifySpeakers` to: short-circuit with a clear message if Eagle is unavailable; decode the input to PCM once; group utterances by label; recognize against enrolled profiles (auto-name ≥ threshold, prompt the tentative band on TTY); capture a per-speaker clip and return it so the caller can persist it in the history record. The function signature gains the `config` (for the AccessKey) and returns both renamed segments and the captured clips.

- [ ] **Step 1: Write the failing test** (pure helper — clip selection)

```typescript
// tests/orchestrator.test.ts
import { selectClipRanges } from "../src/orchestrator.js";
it("selectClipRanges picks the longest utterances up to the target seconds", () => {
  const segs = [
    { start: 0, end: 2, text: "", speaker: "Speaker 1" },
    { start: 5, end: 15, text: "", speaker: "Speaker 1" },
    { start: 20, end: 22, text: "", speaker: "Speaker 1" },
  ];
  const ranges = selectClipRanges(segs, "Speaker 1", 10);
  // longest first (10s) covers the target; stop there.
  expect(ranges).toEqual([{ start: 5, end: 15 }]);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/orchestrator.test.ts`
Expected: FAIL — `selectClipRanges` not exported.

- [ ] **Step 3: Write the implementation**

Add the exported helper and rewrite `identifySpeakers`. Replace the speakers.ts imports (`extractEmbeddings, matchSpeakers, clusterLabels`) with `matchProfiles, loadProfiles, applySpeakerNames, promptForSpeakerNames`, and import `decodePcm, slicePcm, concatToSeconds` from `../utils/pcm.js`, `isEagleAvailable, enrollProfile, MATCH_THRESHOLD` from `./pipeline/eagle.js`, and `writeSpeakerClip` from history.

```typescript
import type { TranscriptSegment } from "./pipeline/transcribe.js";

export const CLIP_TARGET_SEC = 24;
export const CLIP_MIN_SEC = 5;

/** Longest utterances for a label, concatenated up to `targetSec` of audio. */
export function selectClipRanges(
  segments: TranscriptSegment[], label: string, targetSec: number,
): { start: number; end: number }[] {
  const mine = segments.filter((s) => s.speaker === label)
    .map((s) => ({ start: s.start, end: s.end }))
    .sort((a, b) => (b.end - b.start) - (a.end - a.start));
  const picked: { start: number; end: number }[] = [];
  let acc = 0;
  for (const r of mine) { if (acc >= targetSec) break; picked.push(r); acc += r.end - r.start; }
  return picked;
}
```

New `identifySpeakers` (returns segments + clips to persist):
```typescript
interface IdentifyOutput {
  segments: TranscriptSegment[];
  clips: Record<string, Int16Array>; // label → PCM clip to persist
}

async function identifySpeakers(
  inputPath: string, segments: TranscriptSegment[], config: AppConfig, verbose: boolean,
): Promise<IdentifyOutput> {
  if (!isEagleAvailable(config.picovoiceAccessKey)) {
    console.error("Speaker identity unavailable: set PICOVOICE_ACCESS_KEY (free at https://console.picovoice.ai). Using generic labels.");
    return { segments, clips: {} };
  }
  const key = config.picovoiceAccessKey!;
  let spinner = log(verbose, "Identifying speakers (Eagle)...");
  try {
    const pcm = await decodePcm(inputPath);
    const labels = [...new Set(segments.map((s) => s.speaker).filter(Boolean) as string[])];
    const pcmByLabel: Record<string, Int16Array> = {};
    const clips: Record<string, Int16Array> = {};
    for (const label of labels) {
      const ranges = selectClipRanges(segments, label, CLIP_TARGET_SEC);
      const clip = concatToSeconds(ranges.map((r) => slicePcm(pcm, [r])), CLIP_TARGET_SEC);
      pcmByLabel[label] = clip;
      if (clip.length >= CLIP_MIN_SEC * 16000) clips[label] = clip; // enrollable later
    }
    const store = await loadProfiles();
    const matches = matchProfiles(key, pcmByLabel, store);
    spinner?.succeed("Speaker identification complete");

    const nameMap: Record<string, string> = {};
    const tentative: Record<string, { name: string; confidence: number }> = {};
    for (const [label, m] of Object.entries(matches)) {
      if (m.tentative) tentative[label] = { name: m.name, confidence: m.confidence };
      else nameMap[label] = m.name;
    }
    const unmatched = labels.filter((l) => !nameMap[l] && !tentative[l]);
    if ((unmatched.length || Object.keys(tentative).length) && process.stdin.isTTY) {
      const { names } = await promptForSpeakerNames(segments, unmatched, tentative);
      Object.assign(nameMap, names);
      // NOTE: fresh enrollment now happens via `nota enroll` from the stored
      // clip after the history record is written (Task 7), so the interactive
      // prompt only assigns display names here.
    }
    return { segments: applySpeakerNames(segments, nameMap), clips };
  } catch (error) {
    spinner?.fail("Speaker identification unavailable (using generic labels)");
    if (verbose) console.error(`  ${error instanceof Error ? error.message : String(error)}`);
    return { segments, clips: {} };
  }
}
```

Update the AssemblyAI call site (currently around `identifySpeakers(audioForEmbeddings, segments, verbose)`):
```typescript
  let segments = result.segments;
  let speakerClips: Record<string, string> | undefined;
  if (config.identify) {
    const audioForId = localAudioPath ?? inputPath;
    const ident = await identifySpeakers(audioForId, segments, config, verbose);
    segments = ident.segments;
    // capture clips keyed by the FINAL (possibly renamed) labels' originals:
    // persist under the diarized label so `nota enroll <id> <label>` resolves.
    if (config.history && Object.keys(ident.clips).length) {
      speakerClips = {}; // filled after we know the history id (below)
      (runAssemblyAIPipelineInner as any)._pendingClips = ident.clips;
    }
  }
```

> Simpler, preferred wiring (avoids the stashed-state hack above): capture `ident.clips` in a local, create the history record, then write clips and patch the record. Concretely, after `createHistoryRecord(...)` returns `history`, do:
```typescript
  if (config.history && config.identify) {
    const written: Record<string, string> = {};
    for (const [label, clip] of Object.entries(ident.clips))
      written[label] = await writeSpeakerClip(history.id, label, clip);
    if (Object.keys(written).length) {
      // persist the pointers on the record
      const rec = await loadHistoryRecord(history.id);
      await /* save */ writeHistoryRecord({ ...rec, speakerClips: written });
    }
  }
```
Add a small `writeHistoryRecord(record)` export to `history.ts` (writes `<id>.json`) if one does not already exist, OR extend `createHistoryRecord` to accept `speakerClips` directly and pass it in the create call (cleanest — preferred). **Preferred:** thread `ident.clips` → write clips BEFORE `createHistoryRecord` → pass `speakerClips` into `createHistoryRecord({ ..., speakerClips })`. Reorder so clips are written first using `history.id`… which requires the id. Since the id is generated inside `createHistoryRecord`, add an optional `speakerClipsPcm?: Record<string, Int16Array>` input to `createHistoryRecord` that it writes via `writeSpeakerClip(record.id, …)` and records as `speakerClips`. Implement that variant in Task 5's `createHistoryRecord` instead of the stash hack.

- [ ] **Step 3b: Adjust Task 5 `createHistoryRecord`** to accept and persist clips:
```typescript
// CreateHistoryInput gains:
  speakerClipsPcm?: Record<string, Int16Array>;
// inside createHistoryRecord, after the record object is built and id known:
  if (input.speakerClipsPcm) {
    const clips: Record<string, string> = {};
    for (const [label, pcm] of Object.entries(input.speakerClipsPcm))
      clips[label] = await writeSpeakerClip(record.id, label, pcm, historyDir);
    record.speakerClips = clips;
  }
// then write the JSON (existing writeFile call) — ensure it serializes speakerClips.
```
And the orchestrator simply passes `speakerClipsPcm: ident.clips` into the existing `createHistoryRecord({ … })` call. Apply the identical change at the Whisper call site (`runWhisperPipeline`).

- [ ] **Step 4: Run tests**

Run: `npx vitest run tests/orchestrator.test.ts && npm run build`
Expected: helper test PASS; `tsc` clean.

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator.ts src/pipeline/history.ts tests/orchestrator.test.ts
git commit -m "feat(identify): Eagle recognition + per-speaker clip capture during the run"
```

---

## Task 7: Enroll from stored clip (`src/cli/enroll.ts`)

**Files:**
- Modify: `src/cli/enroll.ts`
- Test: `tests/cli/enroll.test.ts`

Replace pyannote extraction with: resolve `record.speakerClips[label]`, read the stored PCM, `enrollProfile` via Eagle, append the base64 profile. Exit codes: 2 record-not-found, 3 stored-clip-missing, 4 Eagle-unavailable (no AccessKey), 5 insufficient-speech, 1 other.

- [ ] **Step 1: Write the failing test**

```typescript
// tests/cli/enroll.test.ts — add
it("exits 3 when the speaker clip pointer is missing", async () => {
  // build a history record WITHOUT speakerClips
  // (reuse the suite's helper that writes a record to a temp historyDir)
  await expect(enrollSpeaker(recordId, "Speaker 1", "Alice",
    { storePath, historyDir, accessKey: "pv-test" }))
    .rejects.toMatchObject({ exitCode: 3 });
});
it("exits 4 when no AccessKey is provided", async () => {
  await expect(enrollSpeaker(recordId, "Speaker 1", "Alice",
    { storePath, historyDir, accessKey: undefined }))
    .rejects.toMatchObject({ exitCode: 4 });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/cli/enroll.test.ts`
Expected: FAIL — `EnrollOptions` has no `accessKey`; clip path not handled.

- [ ] **Step 3: Write the implementation**

```typescript
import { readFile, access } from "node:fs/promises";
import { speakerClipPath } from "../pipeline/history.js";
import { isEagleAvailable, enrollProfile, InsufficientSpeechError } from "../pipeline/eagle.js";
import { encodeProfile, loadProfiles, saveProfiles, DEFAULT_SPEAKERS_FILE } from "../pipeline/speakers.js";

export interface EnrollOptions { storePath?: string; historyDir?: string; accessKey?: string; }

export async function enrollSpeaker(historyId, label, name, options?): Promise<void> {
  const storePath = options?.storePath ?? DEFAULT_SPEAKERS_FILE;
  const historyDir = options?.historyDir ?? DEFAULT_HISTORY_DIR;
  const accessKey = options?.accessKey ?? process.env.PICOVOICE_ACCESS_KEY;

  if (!isEagleAvailable(accessKey))
    throw new EnrollError("PICOVOICE_ACCESS_KEY is required for Eagle enrollment", 4);

  let record: HistoryRecord;
  try { record = await loadHistoryRecord(historyId, historyDir); }
  catch (e) { throw new EnrollError(e instanceof Error ? e.message : String(e), 2); }

  const rel = record.speakerClips?.[label];
  const clipPath = rel ? speakerClipPath(record.id, label, historyDir) : null;
  if (!clipPath || !(await access(clipPath).then(() => true).catch(() => false)))
    throw new EnrollError(`No stored audio clip for label "${label}" in record "${historyId}"`, 3);

  const buf = await readFile(clipPath);
  const pcm = new Int16Array(buf.buffer, buf.byteOffset, Math.floor(buf.length / 2));

  let profileBytes: Uint8Array;
  try { profileBytes = await enrollProfile(accessKey!, pcm); }
  catch (e) {
    if (e instanceof InsufficientSpeechError) throw new EnrollError(e.message, 5);
    throw new EnrollError(e instanceof Error ? e.message : String(e), 1);
  }

  const store = await loadProfiles(storePath);
  const now = new Date().toISOString();
  const vp = { id: now, profile: encodeProfile(profileBytes), enrolledAt: now, source: record.sourceName };
  if (store.speakers[name]) store.speakers[name].voiceprints.push(vp);
  else store.speakers[name] = { voiceprints: [vp] };
  await saveProfiles(store, storePath);
  process.stderr.write(`Enrolled "${label}" from history "${historyId}" as "${name}".\n`);
}
```
Update the exit-code comment block to list 5. Keep the `EnrollError` class.

- [ ] **Step 4: Run tests**

Run: `npx vitest run tests/cli/enroll.test.ts && npm run build`
Expected: PASS; `tsc` clean. (Remove/replace old tests asserting exit-4-on-pyannote; the new exit 4 = no AccessKey.)

- [ ] **Step 5: Commit**

```bash
git add src/cli/enroll.ts tests/cli/enroll.test.ts
git commit -m "feat(enroll): enroll from stored PCM clip via Eagle; exit 5 on insufficient speech"
```

---

## Task 8: Docs + cleanup

**Files:**
- Modify: `CLAUDE.md`
- Delete: `scripts/embeddings.py` (no longer referenced)

- [ ] **Step 1: Verify embeddings.py is unreferenced**

Run: `grep -rn "embeddings.py\|extractEmbeddings\|cosineSimilarity\|matchSpeakers\|clusterLabels" src/ tests/`
Expected: no hits (all removed in Tasks 4/6/7). If hits remain, fix them before deleting.

- [ ] **Step 2: Update CLAUDE.md**

In **External Requirements**, replace the pyannote line for identity with:
`- For speaker identity (\`--identify\` / viewer naming): \`PICOVOICE_ACCESS_KEY\` (free, on-device Eagle). pyannote is now only used for \`--provider whisper\` diarization.`

In **Speaker Management** / **Key Design Decisions**, add a bullet:
`- Speaker identity uses on-device Picovoice Eagle. Embeddings/clips are captured during the run (audio is a temp file deleted afterward); naming later enrolls from the stored clip under \`~/.nota/history/<id>.assets/\`. Store schema v3 holds base64 Eagle profiles; legacy pyannote profiles are dropped on load.`

Update the `nota speakers list`/`show` lines: replace "embedding length"/"embedding truncated to first 8 dims" with "profile size (bytes)".

- [ ] **Step 3: Delete the dead script**

Run: `git rm scripts/embeddings.py`

- [ ] **Step 4: Full suite + build**

Run: `npm test && npm run build`
Expected: all green; `tsc` clean.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(speakers): Eagle identity backend; remove pyannote embedding script"
```

---

## Self-Review (completed during planning)

- **Spec coverage:** Eagle backend (T2), capture-during-run + clips (T1/T5/T6), audio-free enroll (T7), store v3 + legacy drop (T4), config/AccessKey (T3), error surfaces incl. exit 5 (T7) and no-key message (T6), docs/cleanup (T8). All spec sections mapped.
- **Known scope cut (flagged):** Eagle gives scores, not vectors, so the old `clusterLabels` near-duplicate diarizer-label merge is removed. A speaker split by the diarizer into two labels may enroll twice. Acceptable for MVP per spec "Open / future"; revisit with score-based clustering if it bites.
- **Type consistency:** `Voiceprint.profile` (base64) used in T4/T7; `encodeProfile`/`decodeProfile` defined T4, used T4/T6/T7. `recognize` returns `{index,score}` per label (T2) consumed by `matchProfiles` (T4). `writeSpeakerClip`/`speakerClipPath` defined T5, used T6/T7. `enrollProfile`/`InsufficientSpeechError`/`isEagleAvailable` defined T2, used T6/T7. `picovoiceAccessKey` defined T3, used T6/T7.
- **Placeholder scan:** Task 6 wiring intentionally shows a rejected hack then the preferred `speakerClipsPcm`-into-`createHistoryRecord` approach — implement the preferred one. No other placeholders.

## Revisions

- r1 (2026-06-04) — initial plan from the approved design.
