# Speaker Diarization Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add speaker identification to MeetingSum using pyannote.audio via a Python subprocess, enabled by default with `--no-diarize` opt-out.

**Architecture:** A bundled Python script runs pyannote diarization on the full audio file. Node.js calls it via `child_process.execFile`, parses JSON output, and aligns speaker labels with Whisper's timestamped segments by maximum time overlap. Diarization runs in parallel with transcription.

**Tech Stack:** Python 3.8+ (pyannote.audio, torch), existing TypeScript/Node.js stack

**Spec:** `docs/superpowers/specs/2026-03-10-speaker-diarization-design.md`

---

## File Structure

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `scripts/diarize.py` | Python script: runs pyannote, outputs JSON to stdout |
| Create | `src/pipeline/diarize.ts` | Node wrapper: spawns Python, parses output, aligns speakers |
| Create | `tests/pipeline/diarize.test.ts` | Tests for alignment logic and Python runner |
| Modify | `src/pipeline/transcribe.ts:5-9` | Add `speaker?` field to `TranscriptSegment` |
| Modify | `src/pipeline/merge.ts:24-30` | Use spread operator to preserve extra fields like `speaker` |
| Modify | `src/pipeline/validate.ts` | Add `checkPython()` and `checkHuggingFaceToken()` |
| Modify | `tests/pipeline/validate.test.ts` | Tests for new validation checks |
| Modify | `src/config.ts` | Add `diarize: boolean` to `AppConfig` |
| Modify | `tests/config.test.ts` | Test diarize config option |
| Modify | `src/index.ts` | Add `--no-diarize` CLI flag |
| Modify | `tests/index.test.ts` | Test `--no-diarize` appears in help |
| Modify | `src/orchestrator.ts` | Parallel diarization + transcription, align after |
| Modify | `src/pipeline/write.ts` | Speaker labels in transcript output |
| Modify | `tests/pipeline/write.test.ts` | Test speaker label rendering |
| Modify | `src/pipeline/summarize.ts` | Speaker-aware prompt for GPT |
| Modify | `tests/pipeline/summarize.test.ts` | Test speaker-labeled prompt |

---

## Chunk 1: Python Script & Core Diarize Module

### Task 1: Create the Python diarization script

**Files:**
- Create: `scripts/diarize.py`

- [ ] **Step 1: Create the Python script**

Create `scripts/diarize.py`:

```python
#!/usr/bin/env python3
"""Speaker diarization using pyannote.audio. Outputs JSON to stdout."""

import json
import os
import sys

def main():
    if len(sys.argv) != 2:
        print("Usage: diarize.py <audio-file>", file=sys.stderr)
        sys.exit(1)

    audio_path = sys.argv[1]
    token = os.environ.get("HUGGINGFACE_TOKEN")
    if not token:
        print("HUGGINGFACE_TOKEN environment variable is required", file=sys.stderr)
        sys.exit(1)

    try:
        from pyannote.audio import Pipeline
    except ImportError:
        print("pyannote.audio is not installed. Run: pip install pyannote.audio torch", file=sys.stderr)
        sys.exit(1)

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=token,
    )

    diarization = pipeline(audio_path)

    segments = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append({
            "start": round(turn.start, 3),
            "end": round(turn.end, 3),
            "speaker": speaker,
        })

    json.dump(segments, sys.stdout)

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Make the script executable**

```bash
chmod +x scripts/diarize.py
```

- [ ] **Step 3: Commit**

```bash
git add scripts/diarize.py
git commit -m "feat: add pyannote speaker diarization Python script"
```

---

### Task 2: Add `speaker` field to `TranscriptSegment`

**Files:**
- Modify: `src/pipeline/transcribe.ts:5-9`

- [ ] **Step 1: Add the optional speaker field**

In `src/pipeline/transcribe.ts`, change the `TranscriptSegment` interface from:

```typescript
export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
}
```

to:

```typescript
export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
  speaker?: string;
}
```

- [ ] **Step 2: Run existing tests to confirm nothing breaks**

Run: `npx vitest run`
Expected: All existing tests pass (the new field is optional, so all existing code is unaffected).

- [ ] **Step 3: Commit**

```bash
git add src/pipeline/transcribe.ts
git commit -m "feat: add optional speaker field to TranscriptSegment"
```

---

### Task 3: Fix merge.ts to preserve extra segment properties

**Files:**
- Modify: `src/pipeline/merge.ts:24-30`
- Modify: `tests/pipeline/merge.test.ts`

The merge function constructs new segment objects with only `{ start, end, text }`, which would silently drop any additional properties like `speaker`. Fix it to use the spread operator.

- [ ] **Step 1: Write a test that verifies extra properties are preserved**

Add to `tests/pipeline/merge.test.ts`:

```typescript
it("preserves extra properties on segments through merge", () => {
  const overlap = 30;
  const input: TranscriptionResult[] = [
    {
      segments: [
        { start: 0, end: 300, text: "First part", speaker: "Speaker 1" } as any,
      ],
      text: "First part",
    },
    {
      segments: [
        { start: 0, end: 30, text: "overlap" },
        { start: 30, end: 300, text: "Second part", speaker: "Speaker 2" } as any,
      ],
      text: "overlap Second part",
    },
  ];
  const result = mergeTranscriptions(input, overlap);
  expect((result.segments[0] as any).speaker).toBe("Speaker 1");
  expect((result.segments[1] as any).speaker).toBe("Speaker 2");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/merge.test.ts`
Expected: FAIL — the `speaker` property is dropped during merge.

- [ ] **Step 3: Fix merge.ts to use spread operator**

In `src/pipeline/merge.ts`, change the non-overlap segment mapping from:

```typescript
for (const seg of nonOverlap) {
  merged.push({
    start: seg.start - overlapSeconds + timeOffset,
    end: seg.end - overlapSeconds + timeOffset,
    text: seg.text,
  });
}
```

to:

```typescript
for (const seg of nonOverlap) {
  merged.push({
    ...seg,
    start: seg.start - overlapSeconds + timeOffset,
    end: seg.end - overlapSeconds + timeOffset,
  });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/merge.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/merge.ts tests/pipeline/merge.test.ts
git commit -m "fix: preserve extra segment properties through merge"
```

---

### Task 4: Create `src/pipeline/diarize.ts` with alignment logic

**Files:**
- Create: `src/pipeline/diarize.ts`
- Create: `tests/pipeline/diarize.test.ts`

- [ ] **Step 1: Write tests for `alignSpeakers`**

Create `tests/pipeline/diarize.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { alignSpeakers, humanizeSpeaker } from "../../src/pipeline/diarize.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";
import type { DiarizationSegment } from "../../src/pipeline/diarize.js";

describe("humanizeSpeaker", () => {
  it("converts SPEAKER_00 to Speaker 1", () => {
    expect(humanizeSpeaker("SPEAKER_00")).toBe("Speaker 1");
  });

  it("converts SPEAKER_02 to Speaker 3", () => {
    expect(humanizeSpeaker("SPEAKER_02")).toBe("Speaker 3");
  });

  it("returns unknown speakers as-is", () => {
    expect(humanizeSpeaker("UNKNOWN")).toBe("UNKNOWN");
  });
});

describe("alignSpeakers", () => {
  it("assigns speaker to segment with maximum overlap", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello" },
      { start: 5, end: 10, text: "World" },
    ];
    const diarization: DiarizationSegment[] = [
      { start: 0, end: 6, speaker: "SPEAKER_00" },
      { start: 6, end: 10, speaker: "SPEAKER_01" },
    ];
    const result = alignSpeakers(segments, diarization);
    expect(result[0].speaker).toBe("Speaker 1");
    expect(result[1].speaker).toBe("Speaker 2");
  });

  it("leaves speaker undefined when no diarization overlaps", () => {
    const segments: TranscriptSegment[] = [
      { start: 100, end: 110, text: "Late segment" },
    ];
    const diarization: DiarizationSegment[] = [
      { start: 0, end: 5, speaker: "SPEAKER_00" },
    ];
    const result = alignSpeakers(segments, diarization);
    expect(result[0].speaker).toBeUndefined();
  });

  it("handles empty diarization array", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello" },
    ];
    const result = alignSpeakers(segments, []);
    expect(result[0].speaker).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/pipeline/diarize.test.ts`
Expected: FAIL — module `../../src/pipeline/diarize.js` does not exist.

- [ ] **Step 3: Implement `diarize.ts`**

Create `src/pipeline/diarize.ts`:

```typescript
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { TranscriptSegment } from "./transcribe.js";

const execFileAsync = promisify(execFile);

export interface DiarizationSegment {
  start: number;
  end: number;
  speaker: string;
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const SCRIPT_PATH = path.resolve(__dirname, "../../scripts/diarize.py");

export async function runDiarization(
  audioPath: string
): Promise<DiarizationSegment[]> {
  const { stdout, stderr } = await execFileAsync("python3", [
    SCRIPT_PATH,
    audioPath,
  ], { maxBuffer: 50 * 1024 * 1024 });

  if (!stdout.trim()) {
    throw new Error(
      `Diarization produced no output${stderr ? `: ${stderr}` : ""}`
    );
  }

  const segments: DiarizationSegment[] = JSON.parse(stdout);
  return segments;
}

export function humanizeSpeaker(speaker: string): string {
  const match = speaker.match(/^SPEAKER_(\d+)$/);
  if (!match) return speaker;
  return `Speaker ${parseInt(match[1], 10) + 1}`;
}

function computeOverlap(
  a: { start: number; end: number },
  b: { start: number; end: number }
): number {
  const start = Math.max(a.start, b.start);
  const end = Math.min(a.end, b.end);
  return Math.max(0, end - start);
}

export function alignSpeakers(
  segments: TranscriptSegment[],
  diarization: DiarizationSegment[]
): TranscriptSegment[] {
  return segments.map((seg) => {
    let bestSpeaker: string | undefined;
    let bestOverlap = 0;

    for (const dia of diarization) {
      const overlap = computeOverlap(seg, dia);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestSpeaker = dia.speaker;
      }
    }

    return {
      ...seg,
      speaker: bestSpeaker ? humanizeSpeaker(bestSpeaker) : undefined,
    };
  });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/diarize.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite**

Run: `npx vitest run`
Expected: All tests pass (existing + new).

- [ ] **Step 6: Commit**

```bash
git add src/pipeline/diarize.ts tests/pipeline/diarize.test.ts
git commit -m "feat: add speaker alignment logic for diarization"
```

---

## Chunk 2: Config, Validation & CLI

### Task 5: Add `diarize` to config

**Files:**
- Modify: `src/config.ts`
- Modify: `tests/config.test.ts`

- [ ] **Step 1: Write the test**

Add to `tests/config.test.ts`:

```typescript
it("defaults diarize to true", () => {
  process.env.OPENAI_API_KEY = "sk-test";
  const config = loadConfig({});
  expect(config.diarize).toBe(true);
});

it("respects diarize false override", () => {
  process.env.OPENAI_API_KEY = "sk-test";
  const config = loadConfig({ diarize: false });
  expect(config.diarize).toBe(false);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/config.test.ts`
Expected: FAIL — `diarize` property doesn't exist on AppConfig.

- [ ] **Step 3: Update config.ts**

In `src/config.ts`, update `CLIOptions`:

```typescript
export interface CLIOptions {
  output?: string;
  language?: string;
  model?: string;
  verbose?: boolean;
  diarize?: boolean;
}
```

Update `AppConfig`:

```typescript
export interface AppConfig {
  openaiApiKey: string;
  summaryModel: string;
  language?: string;
  verbose: boolean;
  diarize: boolean;
}
```

Update `loadConfig` return to include:

```typescript
return {
  openaiApiKey,
  summaryModel: options.model ?? "gpt-4o",
  language: options.language,
  verbose: options.verbose ?? false,
  diarize: options.diarize ?? true,
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/config.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/config.ts tests/config.test.ts
git commit -m "feat: add diarize option to config (default true)"
```

---

### Task 6: Add diarization validation checks

**Files:**
- Modify: `src/pipeline/validate.ts`
- Modify: `tests/pipeline/validate.test.ts`

- [ ] **Step 1: Write tests for new validation**

Add to `tests/pipeline/validate.test.ts`:

```typescript
import { checkPython, checkHuggingFaceToken } from "../../src/pipeline/validate.js";

describe("checkPython", () => {
  it("does not throw when python3 is available", async () => {
    await expect(checkPython()).resolves.not.toThrow();
  });
});

describe("checkHuggingFaceToken", () => {
  it("throws when HUGGINGFACE_TOKEN is not set", () => {
    const original = process.env.HUGGINGFACE_TOKEN;
    delete process.env.HUGGINGFACE_TOKEN;
    try {
      expect(() => checkHuggingFaceToken()).toThrow("HUGGINGFACE_TOKEN");
    } finally {
      if (original) process.env.HUGGINGFACE_TOKEN = original;
    }
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/pipeline/validate.test.ts`
Expected: FAIL — `checkPython` and `checkHuggingFaceToken` are not exported.

- [ ] **Step 3: Implement validation functions**

In `src/pipeline/validate.ts`, add the imports and functions:

```typescript
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
```

Add after the existing `validateInput` function:

```typescript
export async function checkPython(): Promise<void> {
  try {
    await execFileAsync("python3", ["--version"]);
  } catch {
    throw new Error(
      "python3 is not installed or not in PATH. Required for speaker diarization."
    );
  }

  try {
    await execFileAsync("python3", ["-c", "import pyannote.audio"]);
  } catch {
    throw new Error(
      "pyannote.audio is not installed. Run: pip install pyannote.audio torch"
    );
  }
}

export function checkHuggingFaceToken(): void {
  if (!process.env.HUGGINGFACE_TOKEN) {
    throw new Error(
      "HUGGINGFACE_TOKEN environment variable is required for speaker diarization. " +
      "Get one at https://huggingface.co/settings/tokens"
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/validate.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/validate.ts tests/pipeline/validate.test.ts
git commit -m "feat: add python3 and HuggingFace token validation"
```

---

### Task 7: Add `--no-diarize` CLI flag

**Files:**
- Modify: `src/index.ts`
- Modify: `tests/index.test.ts`

- [ ] **Step 1: Write the test**

Add to the `describe("CLI")` block in `tests/index.test.ts`:

```typescript
it("shows --no-diarize in help", () => {
  const output = execFileSync("npx", ["tsx", "src/index.ts", "--help"], {
    encoding: "utf-8",
  });
  expect(output).toContain("--no-diarize");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/index.test.ts`
Expected: FAIL — `--no-diarize` not found in help output.

- [ ] **Step 3: Add the flag to the CLI**

In `src/index.ts`, add after the `--verbose` option:

```typescript
.option("--no-diarize", "Skip speaker identification")
```

And update the action to pass `diarize` to config. Change the `action` callback's config line:

```typescript
const config = loadConfig({ ...options, diarize: options.diarize });
```

Note: Commander automatically handles `--no-diarize` by setting `options.diarize = false`. When not specified, `options.diarize` is `undefined`, which `loadConfig` defaults to `true`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/index.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/index.ts tests/index.test.ts
git commit -m "feat: add --no-diarize CLI flag"
```

---

## Chunk 3: Pipeline Integration

### Task 8: Update orchestrator for parallel diarization

**Files:**
- Modify: `src/orchestrator.ts`

- [ ] **Step 1: Update PipelineOptions and imports**

In `src/orchestrator.ts`, add the import:

```typescript
import { runDiarization, alignSpeakers } from "./pipeline/diarize.js";
import { checkPython, checkHuggingFaceToken } from "./pipeline/validate.js";
```

- [ ] **Step 2: Add diarization validation to step 1**

After `spinner?.succeed("Input validated")`, add:

```typescript
// 1b. Validate diarization requirements
if (config.diarize) {
  spinner = log(verbose, "Checking diarization requirements...");
  await checkPython();
  checkHuggingFaceToken();
  spinner?.succeed("Diarization requirements met");
}
```

- [ ] **Step 3: Run diarization in parallel with transcription**

Replace the existing step 3 (Transcribe) section with parallel execution. Change from:

```typescript
// 3. Transcribe
spinner = log(verbose, `Transcribing ${chunks.length} chunk(s)...`);
const transcriptions = await transcribeChunks(
  chunks,
  config.openaiApiKey,
  config.language
);
spinner?.succeed("Transcription complete");
```

to:

```typescript
// 3. Transcribe (and diarize in parallel if enabled)
spinner = log(verbose, config.diarize
  ? `Transcribing ${chunks.length} chunk(s) and diarizing speakers...`
  : `Transcribing ${chunks.length} chunk(s)...`
);

const [transcriptions, diarization] = await Promise.all([
  transcribeChunks(chunks, config.openaiApiKey, config.language),
  config.diarize ? runDiarization(inputPath) : Promise.resolve(null),
]);
spinner?.succeed(config.diarize
  ? "Transcription and diarization complete"
  : "Transcription complete"
);
```

- [ ] **Step 4: Add speaker alignment after merge**

Change `const merged` to `let merged`:

```typescript
let merged = mergeTranscriptions(transcriptions, OVERLAP_DURATION);
```

Then add after the merge succeed line:

```typescript
// 4b. Align speakers
if (diarization) {
  spinner = log(verbose, "Aligning speaker labels...");
  merged = { ...merged, segments: alignSpeakers(merged.segments, diarization) };
  spinner?.succeed("Speaker labels aligned");
}
```

- [ ] **Step 5: Run full test suite**

Run: `npx vitest run`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/orchestrator.ts
git commit -m "feat: integrate diarization into pipeline with parallel execution"
```

---

### Task 9: Update write.ts for speaker labels

**Files:**
- Modify: `src/pipeline/write.ts`
- Modify: `tests/pipeline/write.test.ts`

- [ ] **Step 1: Write the test**

Add a new test in `tests/pipeline/write.test.ts`:

```typescript
it("includes speaker labels in transcript when present", () => {
  const summary: MeetingSummary = {
    narrative: "A productive meeting.",
    keyTopics: ["**Budget** — discussed allocations"],
    decisions: ["Increase Q3 budget"],
    actionItems: ["[ ] Submit report — assigned to Speaker 1"],
  };
  const segments: TranscriptSegment[] = [
    { start: 0, end: 10, text: "Hello everyone", speaker: "Speaker 1" },
    { start: 10, end: 20, text: "Let's begin", speaker: "Speaker 2" },
    { start: 20, end: 30, text: "Sounds good" },  // no speaker
  ];
  const md = buildMarkdown({
    summary,
    segments,
    date: "2026-03-10",
    duration: 30,
    source: "meeting.mp3",
  });

  expect(md).toContain("[00:00] **Speaker 1:** Hello everyone");
  expect(md).toContain("[00:10] **Speaker 2:** Let's begin");
  expect(md).toContain("[00:20] Sounds good");
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/write.test.ts`
Expected: FAIL — speaker labels not in output.

- [ ] **Step 3: Update `buildMarkdown` in write.ts**

In `src/pipeline/write.ts`, change the `transcriptLines` mapping from:

```typescript
const transcriptLines = segments
  .map((seg) => `${formatTimestamp(seg.start)} ${seg.text}`)
  .join("\n");
```

to:

```typescript
const transcriptLines = segments
  .map((seg) => {
    const timestamp = formatTimestamp(seg.start);
    if (seg.speaker) {
      return `${timestamp} **${seg.speaker}:** ${seg.text}`;
    }
    return `${timestamp} ${seg.text}`;
  })
  .join("\n");
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/write.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/write.ts tests/pipeline/write.test.ts
git commit -m "feat: render speaker labels in transcript output"
```

---

### Task 10: Update summarize.ts for speaker-aware prompt

**Files:**
- Modify: `src/pipeline/summarize.ts`
- Modify: `tests/pipeline/summarize.test.ts`

- [ ] **Step 1: Write the test**

Add to `tests/pipeline/summarize.test.ts`:

```typescript
import { buildSpeakerLabeledTranscript } from "../../src/pipeline/summarize.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";

describe("buildSpeakerLabeledTranscript", () => {
  it("formats segments with speaker labels", () => {
    const segments: TranscriptSegment[] = [
      { start: 0, end: 5, text: "Hello", speaker: "Speaker 1" },
      { start: 5, end: 10, text: "Hi there", speaker: "Speaker 2" },
      { start: 10, end: 15, text: "Let's start" },
    ];
    const result = buildSpeakerLabeledTranscript(segments);
    expect(result).toContain("Speaker 1: Hello");
    expect(result).toContain("Speaker 2: Hi there");
    expect(result).toContain("Let's start");
    expect(result).not.toContain("undefined");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/summarize.test.ts`
Expected: FAIL — `buildSpeakerLabeledTranscript` is not exported.

- [ ] **Step 3: Add the function to summarize.ts**

Add to `src/pipeline/summarize.ts`:

```typescript
import type { TranscriptSegment } from "./transcribe.js";

export function buildSpeakerLabeledTranscript(
  segments: TranscriptSegment[]
): string {
  return segments
    .map((seg) => {
      const prefix = seg.speaker ? `${seg.speaker}: ` : "";
      return `${prefix}${seg.text}`;
    })
    .join("\n");
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/summarize.test.ts`
Expected: All tests pass.

- [ ] **Step 5: Update `summarizeTranscript` to accept segments**

Update the `summarizeTranscript` function signature and body in `src/pipeline/summarize.ts`. Change:

```typescript
export async function summarizeTranscript(
  transcript: string,
  apiKey: string,
  model: string
): Promise<MeetingSummary> {
```

to:

```typescript
export async function summarizeTranscript(
  transcript: string,
  apiKey: string,
  model: string,
  segments?: TranscriptSegment[]
): Promise<MeetingSummary> {
```

Then, at the start of the function body, compute the text to summarize:

```typescript
const textToSummarize = segments
  ? buildSpeakerLabeledTranscript(segments)
  : transcript;
```

Replace `transcript` with `textToSummarize` in the two places it's used:

1. `if (!shouldChunkTranscript(textToSummarize))` (was `transcript`)
2. `const prompt = buildSummaryPrompt(textToSummarize);` (was `transcript`)
3. `const sections = splitTranscriptIntoSections(textToSummarize);` (was `transcript`)

The `segments` parameter is optional, so existing callers (without diarization) continue to work unchanged.

- [ ] **Step 6: Update buildSummaryPrompt for speaker awareness**

In `src/pipeline/summarize.ts`, update `buildSummaryPrompt` to add a speaker instruction when the transcript contains speaker labels. Add after the `## Transcript` section:

Change `buildSummaryPrompt` to accept an optional `hasSpeakers` parameter:

```typescript
export function buildSummaryPrompt(transcript: string, hasSpeakers: boolean = false): string {
```

Add after `${transcript}`:

```typescript
${hasSpeakers ? "\nNote: The transcript includes speaker labels (Speaker 1, Speaker 2, etc.). Use these to attribute decisions, action items, and key points to specific speakers.\n" : ""}
```

Then update the two call sites within the file:
- In the non-chunked path: `const prompt = buildSummaryPrompt(textToSummarize, !!segments);`
- In the chunked path: `const prompt = buildSummaryPrompt(section, !!segments);`

- [ ] **Step 7: Run full test suite**

Run: `npx vitest run`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add src/pipeline/summarize.ts tests/pipeline/summarize.test.ts
git commit -m "feat: add speaker-labeled transcript for summarization"
```

---

### Task 11: Pass segments to summarizer in orchestrator

**Files:**
- Modify: `src/orchestrator.ts`

- [ ] **Step 1: Update the summarize call**

In `src/orchestrator.ts`, change the summarize call from:

```typescript
const summary = await summarizeTranscript(
  merged.text,
  config.openaiApiKey,
  config.summaryModel
);
```

to:

```typescript
const summary = await summarizeTranscript(
  merged.text,
  config.openaiApiKey,
  config.summaryModel,
  diarization ? merged.segments : undefined
);
```

This passes the speaker-labeled segments to the summarizer only when diarization was performed.

- [ ] **Step 2: Run full test suite**

Run: `npx vitest run`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/orchestrator.ts
git commit -m "feat: pass speaker-labeled segments to summarizer"
```

---

## Chunk 4: Documentation

### Task 12: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md**

Add under **Architecture** section, after the `summarize.ts` bullet:

```markdown
  - `diarize.ts` — calls Python pyannote script, aligns speaker labels with transcript segments
```

Add to **External Requirements**:

```markdown
- Python 3.8+ with `pyannote.audio` and `torch` (for speaker diarization)
- Environment variable: `HUGGINGFACE_TOKEN` (for speaker diarization)
```

Add to **Key Design Decisions**:

```markdown
- Speaker diarization via pyannote.audio (Python subprocess), enabled by default
- Diarization runs on full audio file in parallel with chunked transcription
- Speaker labels aligned with Whisper segments by maximum time overlap
- `--no-diarize` flag to skip when Python/pyannote not available
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with diarization details"
```
