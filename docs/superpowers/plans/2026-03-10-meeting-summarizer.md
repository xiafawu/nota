# MeetingSum Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a CLI tool that transcribes audio files via Whisper and summarizes them via Claude, outputting structured markdown.

**Architecture:** Linear pipeline — validate input, chunk large audio via ffmpeg, transcribe chunks in parallel with Whisper API, merge transcripts, summarize with Claude, write markdown. Each pipeline stage is a separate module.

**Tech Stack:** TypeScript, Node.js, commander, openai SDK, @anthropic-ai/sdk, p-limit, vitest, ffmpeg (system)

**Spec:** `docs/superpowers/specs/2026-03-10-meeting-summarizer-design.md`

---

## Chunk 1: Project Scaffolding & Utilities

### Task 1: Initialize project and install dependencies

**Files:**
- Create: `package.json`
- Create: `tsconfig.json`
- Create: `src/index.ts` (placeholder)

- [ ] **Step 1: Initialize the Node.js project**

```bash
cd /Users/xiafawu/Developer/MeetingSum
npm init -y
```

- [ ] **Step 2: Install runtime dependencies (pinned for ESM compatibility)**

```bash
npm install commander openai @anthropic-ai/sdk p-limit@6 ora@8
```

- [ ] **Step 3: Install dev dependencies**

```bash
npm install -D typescript tsx vitest @types/node eslint prettier
```

- [ ] **Step 4: Create tsconfig.json**

Create `tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "Node16",
    "moduleResolution": "Node16",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "declaration": true
  },
  "include": ["src"],
  "exclude": ["node_modules", "dist", "tests"]
}
```

- [ ] **Step 5: Create .gitignore**

Create `.gitignore`:

```
node_modules/
dist/
*.tgz
```

- [ ] **Step 6: Create placeholder entry point**

Create `src/index.ts`:

```typescript
#!/usr/bin/env node
console.log("meetingsum placeholder");
```

- [ ] **Step 7: Create shared constants**

Create `src/constants.ts`:

```typescript
export const SEGMENT_DURATION = 600; // 10 minutes in seconds
export const OVERLAP_DURATION = 30; // 30 seconds overlap
export const CHUNK_THRESHOLD_BYTES = 20 * 1024 * 1024; // 20MB
```

- [ ] **Step 8: Add scripts to package.json**

Add to `package.json` scripts:

```json
{
  "scripts": {
    "dev": "tsx src/index.ts",
    "build": "tsc",
    "test": "vitest run",
    "test:watch": "vitest",
    "start": "node dist/index.js"
  },
  "type": "module",
  "bin": {
    "meetingsum": "dist/index.js"
  }
}
```

- [ ] **Step 9: Verify build works**

Run: `npx tsc --noEmit`
Expected: No errors

- [ ] **Step 10: Commit**

```bash
git add .gitignore package.json package-lock.json tsconfig.json src/index.ts src/constants.ts
git commit -m "feat: initialize project with dependencies and build config"
```

---

### Task 2: Config module — API key validation

**Files:**
- Create: `src/config.ts`
- Create: `tests/config.test.ts`

- [ ] **Step 1: Write failing test for config validation**

Create `tests/config.test.ts`:

```typescript
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { loadConfig } from "../src/config.js";

describe("loadConfig", () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it("throws if OPENAI_API_KEY is missing", () => {
    delete process.env.OPENAI_API_KEY;
    process.env.ANTHROPIC_API_KEY = "sk-ant-test";
    expect(() => loadConfig({})).toThrow("OPENAI_API_KEY");
  });

  it("throws if ANTHROPIC_API_KEY is missing", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    delete process.env.ANTHROPIC_API_KEY;
    expect(() => loadConfig({})).toThrow("ANTHROPIC_API_KEY");
  });

  it("returns config with defaults when keys present", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ANTHROPIC_API_KEY = "sk-ant-test";
    const config = loadConfig({});
    expect(config.openaiApiKey).toBe("sk-test");
    expect(config.anthropicApiKey).toBe("sk-ant-test");
    expect(config.claudeModel).toBe("claude-sonnet-4-20250514");
  });

  it("respects model override", () => {
    process.env.OPENAI_API_KEY = "sk-test";
    process.env.ANTHROPIC_API_KEY = "sk-ant-test";
    const config = loadConfig({ model: "claude-opus-4-20250514" });
    expect(config.claudeModel).toBe("claude-opus-4-20250514");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/config.test.ts`
Expected: FAIL — `loadConfig` not found

- [ ] **Step 3: Implement config module**

Create `src/config.ts`:

```typescript
export interface CLIOptions {
  output?: string;
  language?: string;
  model?: string;
  verbose?: boolean;
}

export interface AppConfig {
  openaiApiKey: string;
  anthropicApiKey: string;
  claudeModel: string;
  language?: string;
  verbose: boolean;
}

export function loadConfig(options: CLIOptions): AppConfig {
  const openaiApiKey = process.env.OPENAI_API_KEY;
  if (!openaiApiKey) {
    throw new Error(
      "OPENAI_API_KEY environment variable is required. Get one at https://platform.openai.com/api-keys"
    );
  }

  const anthropicApiKey = process.env.ANTHROPIC_API_KEY;
  if (!anthropicApiKey) {
    throw new Error(
      "ANTHROPIC_API_KEY environment variable is required. Get one at https://console.anthropic.com/"
    );
  }

  return {
    openaiApiKey,
    anthropicApiKey,
    claudeModel: options.model ?? "claude-sonnet-4-20250514",
    language: options.language,
    verbose: options.verbose ?? false,
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/config.test.ts`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/config.ts tests/config.test.ts
git commit -m "feat: add config module with API key validation"
```

---

### Task 3: ffmpeg utility wrapper

**Files:**
- Create: `src/utils/ffmpeg.ts`
- Create: `tests/utils/ffmpeg.test.ts`

- [ ] **Step 1: Write failing tests for ffmpeg utils**

Create `tests/utils/ffmpeg.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { checkFfmpeg, getAudioDuration } from "../../src/utils/ffmpeg.js";

describe("checkFfmpeg", () => {
  it("resolves if ffmpeg is installed", async () => {
    await expect(checkFfmpeg()).resolves.not.toThrow();
  });
});

describe("getAudioDuration", () => {
  it("throws for nonexistent file", async () => {
    await expect(getAudioDuration("/tmp/nonexistent.mp3")).rejects.toThrow();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `npx vitest run tests/utils/ffmpeg.test.ts`
Expected: FAIL — modules not found

- [ ] **Step 3: Implement ffmpeg utility**

Create `src/utils/ffmpeg.ts`:

```typescript
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function checkFfmpeg(): Promise<void> {
  try {
    await execFileAsync("ffmpeg", ["-version"]);
  } catch {
    throw new Error(
      "ffmpeg is not installed or not in PATH. Install it: https://ffmpeg.org/download.html"
    );
  }
}

export async function getAudioDuration(filePath: string): Promise<number> {
  const { stdout } = await execFileAsync("ffprobe", [
    "-v", "quiet",
    "-show_entries", "format=duration",
    "-of", "csv=p=0",
    filePath,
  ]);
  const duration = parseFloat(stdout.trim());
  if (isNaN(duration)) {
    throw new Error(`Could not determine duration for ${filePath}`);
  }
  return duration;
}

export async function getFileSize(filePath: string): Promise<number> {
  const { stat } = await import("node:fs/promises");
  const stats = await stat(filePath);
  return stats.size;
}

export async function splitAudio(
  inputPath: string,
  outputDir: string,
  segmentDuration: number,
  overlap: number
): Promise<string[]> {
  const duration = await getAudioDuration(inputPath);
  const segments: string[] = [];
  let start = 0;
  let index = 0;

  while (start < duration) {
    const outputPath = `${outputDir}/chunk_${String(index).padStart(3, "0")}.mp3`;
    const segEnd = Math.min(start + segmentDuration + overlap, duration);
    const segLength = segEnd - start;

    await execFileAsync("ffmpeg", [
      "-y",
      "-i", inputPath,
      "-ss", String(start),
      "-t", String(segLength),
      "-acodec", "libmp3lame",
      "-q:a", "4",
      outputPath,
    ]);

    segments.push(outputPath);
    start += segmentDuration;
    index++;
  }

  return segments;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/utils/ffmpeg.test.ts`
Expected: All tests PASS (assuming ffmpeg is installed)

- [ ] **Step 5: Commit**

```bash
git add src/utils/ffmpeg.ts tests/utils/ffmpeg.test.ts
git commit -m "feat: add ffmpeg utility wrapper for audio splitting"
```

---

### Task 4: Token counting utility

**Files:**
- Create: `src/utils/tokens.ts`
- Create: `tests/utils/tokens.test.ts`

- [ ] **Step 1: Write failing test**

Create `tests/utils/tokens.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { estimateTokens, shouldChunkTranscript } from "../../src/utils/tokens.js";

describe("estimateTokens", () => {
  it("estimates roughly 1 token per 4 characters", () => {
    const text = "a".repeat(400);
    const tokens = estimateTokens(text);
    expect(tokens).toBeGreaterThanOrEqual(90);
    expect(tokens).toBeLessThanOrEqual(110);
  });
});

describe("shouldChunkTranscript", () => {
  it("returns false for short text", () => {
    expect(shouldChunkTranscript("short text")).toBe(false);
  });

  it("returns true for very long text", () => {
    const longText = "word ".repeat(200000);
    expect(shouldChunkTranscript(longText)).toBe(true);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/utils/tokens.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement token counting**

Create `src/utils/tokens.ts`:

```typescript
const CHARS_PER_TOKEN = 4;
const MAX_TRANSCRIPT_TOKENS = 100_000;

export function estimateTokens(text: string): number {
  return Math.ceil(text.length / CHARS_PER_TOKEN);
}

export function shouldChunkTranscript(transcript: string): boolean {
  return estimateTokens(transcript) > MAX_TRANSCRIPT_TOKENS;
}

export function splitTranscriptIntoSections(
  transcript: string,
  maxTokensPerSection: number = 50_000
): string[] {
  const lines = transcript.split("\n");
  const sections: string[] = [];
  let current: string[] = [];
  let currentTokens = 0;

  for (const line of lines) {
    const lineTokens = estimateTokens(line);
    if (currentTokens + lineTokens > maxTokensPerSection && current.length > 0) {
      sections.push(current.join("\n"));
      current = [];
      currentTokens = 0;
    }
    current.push(line);
    currentTokens += lineTokens;
  }

  if (current.length > 0) {
    sections.push(current.join("\n"));
  }

  return sections;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/utils/tokens.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/utils/tokens.ts tests/utils/tokens.test.ts
git commit -m "feat: add token estimation utility"
```

---

## Chunk 2: Pipeline Stages

### Task 5: Validate stage

**Files:**
- Create: `src/pipeline/validate.ts`
- Create: `tests/pipeline/validate.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/pipeline/validate.test.ts`:

```typescript
import { describe, it, expect, vi } from "vitest";
import { validateInput } from "../../src/pipeline/validate.js";

describe("validateInput", () => {
  it("throws for nonexistent file", async () => {
    await expect(validateInput("/tmp/does-not-exist.mp3")).rejects.toThrow(
      "does not exist"
    );
  });

  it("throws for unsupported extension", async () => {
    // Create a temp file with bad extension
    const { writeFile, unlink } = await import("node:fs/promises");
    const path = "/tmp/test-validate.txt";
    await writeFile(path, "fake");
    try {
      await expect(validateInput(path)).rejects.toThrow("Unsupported");
    } finally {
      await unlink(path);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/validate.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement validate stage**

Create `src/pipeline/validate.ts`:

```typescript
import { access } from "node:fs/promises";
import path from "node:path";
import { checkFfmpeg } from "../utils/ffmpeg.js";

const SUPPORTED_EXTENSIONS = new Set([
  ".mp3", ".wav", ".m4a", ".ogg", ".webm", ".flac",
]);

export async function validateInput(filePath: string): Promise<void> {
  // Check file exists
  try {
    await access(filePath);
  } catch {
    throw new Error(`File does not exist: ${filePath}`);
  }

  // Check extension
  const ext = path.extname(filePath).toLowerCase();
  if (!SUPPORTED_EXTENSIONS.has(ext)) {
    throw new Error(
      `Unsupported audio format: ${ext}. Supported: ${[...SUPPORTED_EXTENSIONS].join(", ")}`
    );
  }

  // Check ffmpeg
  await checkFfmpeg();
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/validate.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/validate.ts tests/pipeline/validate.test.ts
git commit -m "feat: add input validation pipeline stage"
```

---

### Task 6: Chunk stage

**Files:**
- Create: `src/pipeline/chunk.ts`
- Create: `tests/pipeline/chunk.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/pipeline/chunk.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { chunkAudio, CHUNK_THRESHOLD_BYTES } from "../../src/pipeline/chunk.js";

describe("chunkAudio", () => {
  it("exports the chunk threshold constant", () => {
    expect(CHUNK_THRESHOLD_BYTES).toBe(20 * 1024 * 1024);
  });
});

describe("chunkAudio", () => {
  it("returns single-element array for small files", async () => {
    // Create a tiny temp file
    const { writeFile, unlink } = await import("node:fs/promises");
    const path = "/tmp/test-tiny.mp3";
    await writeFile(path, Buffer.alloc(100));
    try {
      const chunks = await chunkAudio(path);
      expect(chunks).toEqual([path]);
    } finally {
      await unlink(path);
    }
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/chunk.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement chunk stage**

Create `src/pipeline/chunk.ts`:

```typescript
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { getFileSize, splitAudio } from "../utils/ffmpeg.js";
import { CHUNK_THRESHOLD_BYTES, SEGMENT_DURATION, OVERLAP_DURATION } from "../constants.js";

export { CHUNK_THRESHOLD_BYTES };

export async function chunkAudio(filePath: string): Promise<string[]> {
  const size = await getFileSize(filePath);

  if (size <= CHUNK_THRESHOLD_BYTES) {
    return [filePath];
  }

  const tempDir = await mkdtemp(path.join(tmpdir(), "meetingsum-"));
  return splitAudio(filePath, tempDir, SEGMENT_DURATION, OVERLAP_DURATION);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/chunk.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/chunk.ts tests/pipeline/chunk.test.ts
git commit -m "feat: add audio chunking pipeline stage"
```

---

### Task 7: Transcribe stage

**Files:**
- Create: `src/pipeline/transcribe.ts`
- Create: `tests/pipeline/transcribe.test.ts`

- [ ] **Step 1: Write failing tests with mocked OpenAI**

Create `tests/pipeline/transcribe.test.ts`:

```typescript
import { describe, it, expect, vi } from "vitest";
import { formatTimestamp } from "../../src/pipeline/transcribe.js";

describe("formatTimestamp", () => {
  it("formats seconds to [MM:SS]", () => {
    expect(formatTimestamp(0)).toBe("[00:00]");
    expect(formatTimestamp(65)).toBe("[01:05]");
    expect(formatTimestamp(3661)).toBe("[61:01]");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/transcribe.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement transcribe stage**

Create `src/pipeline/transcribe.ts`:

```typescript
import { createReadStream } from "node:fs";
import OpenAI from "openai";
import pLimit from "p-limit";

export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
}

export interface TranscriptionResult {
  segments: TranscriptSegment[];
  text: string;
}

export function formatTimestamp(seconds: number): string {
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `[${String(mins).padStart(2, "0")}:${String(secs).padStart(2, "0")}]`;
}

export async function transcribeChunks(
  chunkPaths: string[],
  apiKey: string,
  language?: string
): Promise<TranscriptionResult[]> {
  const client = new OpenAI({ apiKey });
  const limit = pLimit(3);

  const results = await Promise.all(
    chunkPaths.map((chunkPath, index) =>
      limit(async () => {
        const response = await client.audio.transcriptions.create({
          file: createReadStream(chunkPath),
          model: "whisper-1",
          response_format: "verbose_json",
          timestamp_granularities: ["segment"],
          ...(language ? { language } : {}),
        });

        const segments: TranscriptSegment[] = (
          (response as any).segments ?? []
        ).map((seg: any) => ({
          start: seg.start,
          end: seg.end,
          text: seg.text.trim(),
        }));

        return {
          segments,
          text: response.text,
        };
      })
    )
  );

  return results;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/transcribe.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/transcribe.ts tests/pipeline/transcribe.test.ts
git commit -m "feat: add Whisper transcription pipeline stage"
```

---

### Task 8: Merge stage

**Files:**
- Create: `src/pipeline/merge.ts`
- Create: `tests/pipeline/merge.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/pipeline/merge.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { mergeTranscriptions } from "../../src/pipeline/merge.js";
import type { TranscriptionResult } from "../../src/pipeline/transcribe.js";

describe("mergeTranscriptions", () => {
  it("returns single transcription as-is", () => {
    const input: TranscriptionResult[] = [
      {
        segments: [{ start: 0, end: 10, text: "Hello world" }],
        text: "Hello world",
      },
    ];
    const result = mergeTranscriptions(input, 0);
    expect(result.segments).toHaveLength(1);
    expect(result.text).toBe("Hello world");
  });

  it("merges two transcriptions, drops overlap, and offsets timestamps", () => {
    const overlap = 30; // matches OVERLAP_DURATION
    const input: TranscriptionResult[] = [
      {
        segments: [
          { start: 0, end: 300, text: "First part" },
          { start: 300, end: 600, text: "End of first chunk" },
        ],
        text: "First part End of first chunk",
      },
      {
        segments: [
          { start: 0, end: 30, text: "End of first chunk" }, // overlap — should be dropped
          { start: 30, end: 300, text: "Second part" },
        ],
        text: "End of first chunk Second part",
      },
    ];
    const result = mergeTranscriptions(input, overlap);
    // First chunk: 2 segments, second chunk: 1 non-overlap segment = 3 total
    expect(result.segments).toHaveLength(3);
    // Second chunk's non-overlap segment should be offset by SEGMENT_DURATION (600)
    const lastSeg = result.segments[2];
    expect(lastSeg.start).toBe(600); // 30 - 30 + 600
    expect(lastSeg.text).toBe("Second part");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/merge.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement merge stage**

Create `src/pipeline/merge.ts`:

```typescript
import type { TranscriptionResult, TranscriptSegment } from "./transcribe.js";
import { SEGMENT_DURATION } from "../constants.js";

export function mergeTranscriptions(
  transcriptions: TranscriptionResult[],
  overlapSeconds: number
): TranscriptionResult {
  if (transcriptions.length === 1) {
    return transcriptions[0];
  }

  const merged: TranscriptSegment[] = [];
  let timeOffset = 0;

  for (let i = 0; i < transcriptions.length; i++) {
    const { segments } = transcriptions[i];

    if (i === 0) {
      // First chunk: take all segments
      merged.push(...segments);
      timeOffset = SEGMENT_DURATION;
    } else {
      // Subsequent chunks: skip overlap region, offset timestamps
      const nonOverlap = segments.filter((seg) => seg.start >= overlapSeconds);
      for (const seg of nonOverlap) {
        merged.push({
          start: seg.start - overlapSeconds + timeOffset,
          end: seg.end - overlapSeconds + timeOffset,
          text: seg.text,
        });
      }
      timeOffset += SEGMENT_DURATION;
    }
  }

  const text = merged.map((s) => s.text).join(" ");
  return { segments: merged, text };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/merge.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/merge.ts tests/pipeline/merge.test.ts
git commit -m "feat: add transcript merge stage with overlap dedup"
```

---

### Task 9: Summarize stage

**Files:**
- Create: `src/pipeline/summarize.ts`
- Create: `tests/pipeline/summarize.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/pipeline/summarize.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { buildSummaryPrompt } from "../../src/pipeline/summarize.js";

describe("buildSummaryPrompt", () => {
  it("includes the transcript in the prompt", () => {
    const prompt = buildSummaryPrompt("Hello, this is a test meeting.");
    expect(prompt).toContain("Hello, this is a test meeting.");
    expect(prompt).toContain("Key Topics");
    expect(prompt).toContain("Action Items");
    expect(prompt).toContain("Decisions Made");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/summarize.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement summarize stage**

Create `src/pipeline/summarize.ts`:

```typescript
import Anthropic from "@anthropic-ai/sdk";
import { shouldChunkTranscript, splitTranscriptIntoSections } from "../utils/tokens.js";

export interface MeetingSummary {
  narrative: string;
  keyTopics: string[];
  decisions: string[];
  actionItems: string[];
}

export function buildSummaryPrompt(transcript: string): string {
  return `You are an expert meeting summarizer. Analyze the following meeting transcript and produce a structured summary.

## Transcript

${transcript}

## Instructions

Produce the following sections in your response. Use exactly these headers:

### Summary
Write a concise 2-4 sentence narrative summary of the meeting.

### Key Topics
List each major topic discussed as a bullet point in the format:
- **Topic name** — brief description

### Decisions Made
List each decision made during the meeting:
- Decision — context and rationale

If no decisions were made, write "No explicit decisions were recorded."

### Action Items
List each action item as a checkbox:
- [ ] Action item — assigned to Person (if identifiable from the transcript)

If no action items were identified, write "No action items were identified."`;
}

function buildRollupPrompt(sectionSummaries: string[]): string {
  const combined = sectionSummaries
    .map((s, i) => `## Section ${i + 1}\n\n${s}`)
    .join("\n\n---\n\n");

  return `You are an expert meeting summarizer. The following are summaries of consecutive sections of a long meeting. Combine them into a single coherent summary.

${combined}

## Instructions

Produce a unified summary with these sections using exactly these headers:

### Summary
Write a concise 2-4 sentence narrative summary of the entire meeting.

### Key Topics
Merge and deduplicate topics across all sections:
- **Topic name** — brief description

### Decisions Made
Merge all decisions:
- Decision — context and rationale

### Action Items
Merge all action items, deduplicating:
- [ ] Action item — assigned to Person`;
}

export function parseSummaryResponse(response: string): MeetingSummary {
  const sections = {
    narrative: "",
    keyTopics: [] as string[],
    decisions: [] as string[],
    actionItems: [] as string[],
  };

  const summaryMatch = response.match(
    /### Summary\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (summaryMatch) sections.narrative = summaryMatch[1].trim();

  const topicsMatch = response.match(
    /### Key Topics\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (topicsMatch) {
    sections.keyTopics = topicsMatch[1]
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2));
  }

  const decisionsMatch = response.match(
    /### Decisions Made\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (decisionsMatch) {
    sections.decisions = decisionsMatch[1]
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2));
  }

  const actionsMatch = response.match(
    /### Action Items\s*\n([\s\S]*?)(?=\n### |$)/
  );
  if (actionsMatch) {
    sections.actionItems = actionsMatch[1]
      .trim()
      .split("\n")
      .filter((l) => l.startsWith("- "))
      .map((l) => l.slice(2));
  }

  return sections;
}

async function callClaude(
  client: Anthropic,
  model: string,
  prompt: string
): Promise<string> {
  const message = await client.messages.create({
    model,
    max_tokens: 4096,
    messages: [{ role: "user", content: prompt }],
  });

  const block = message.content[0];
  if (block.type !== "text") throw new Error("Unexpected response type");
  return block.text;
}

export async function summarizeTranscript(
  transcript: string,
  apiKey: string,
  model: string
): Promise<MeetingSummary> {
  const client = new Anthropic({ apiKey });

  if (!shouldChunkTranscript(transcript)) {
    const prompt = buildSummaryPrompt(transcript);
    const response = await callClaude(client, model, prompt);
    return parseSummaryResponse(response);
  }

  // Long transcript: section-by-section then roll up
  const sections = splitTranscriptIntoSections(transcript);
  const sectionSummaries: string[] = [];

  for (const section of sections) {
    const prompt = buildSummaryPrompt(section);
    const response = await callClaude(client, model, prompt);
    sectionSummaries.push(response);
  }

  const rollupPrompt = buildRollupPrompt(sectionSummaries);
  const finalResponse = await callClaude(client, model, rollupPrompt);
  return parseSummaryResponse(finalResponse);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/summarize.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/summarize.ts tests/pipeline/summarize.test.ts
git commit -m "feat: add Claude summarization pipeline stage"
```

---

### Task 10: Write stage

**Files:**
- Create: `src/pipeline/write.ts`
- Create: `tests/pipeline/write.test.ts`

- [ ] **Step 1: Write failing tests**

Create `tests/pipeline/write.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { buildMarkdown } from "../../src/pipeline/write.js";
import type { TranscriptSegment } from "../../src/pipeline/transcribe.js";
import type { MeetingSummary } from "../../src/pipeline/summarize.js";

describe("buildMarkdown", () => {
  it("produces valid markdown with all sections", () => {
    const summary: MeetingSummary = {
      narrative: "A productive meeting.",
      keyTopics: ["**API design** — discussed endpoints"],
      decisions: ["Use REST over GraphQL"],
      actionItems: ["[ ] Write API spec — assigned to Alice"],
    };
    const segments: TranscriptSegment[] = [
      { start: 0, end: 10, text: "Hello everyone" },
      { start: 10, end: 20, text: "Let's discuss the API" },
    ];
    const md = buildMarkdown({
      summary,
      segments,
      date: "2026-03-10",
      duration: 47,
      source: "standup.mp3",
    });

    expect(md).toContain("# Meeting Summary");
    expect(md).toContain("**Date:** 2026-03-10");
    expect(md).toContain("**Duration:** 47 minutes");
    expect(md).toContain("A productive meeting.");
    expect(md).toContain("[00:00]");
    expect(md).toContain("Hello everyone");
    expect(md).toContain("## Full Transcript");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/pipeline/write.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement write stage**

Create `src/pipeline/write.ts`:

```typescript
import { writeFile } from "node:fs/promises";
import path from "node:path";
import type { TranscriptSegment } from "./transcribe.js";
import type { MeetingSummary } from "./summarize.js";
import { formatTimestamp } from "./transcribe.js";

export interface WriteInput {
  summary: MeetingSummary;
  segments: TranscriptSegment[];
  date: string;
  duration: number;
  source: string;
}

export function buildMarkdown(input: WriteInput): string {
  const { summary, segments, date, duration, source } = input;

  const topicLines = summary.keyTopics.map((t) => `- ${t}`).join("\n");
  const decisionLines = summary.decisions.map((d) => `- ${d}`).join("\n");
  const actionLines = summary.actionItems.map((a) => `- ${a}`).join("\n");
  const transcriptLines = segments
    .map((seg) => `${formatTimestamp(seg.start)} ${seg.text}`)
    .join("\n");

  return `# Meeting Summary

**Date:** ${date}
**Duration:** ${duration} minutes
**Source:** ${source}

## Summary

${summary.narrative}

## Key Topics

${topicLines}

## Decisions Made

${decisionLines}

## Action Items

${actionLines}

---

## Full Transcript

${transcriptLines}
`;
}

export async function writeOutput(
  input: WriteInput,
  outputPath: string
): Promise<void> {
  const markdown = buildMarkdown(input);
  await writeFile(outputPath, markdown, "utf-8");
}

export function defaultOutputPath(inputPath: string): string {
  const dir = path.dirname(inputPath);
  const name = path.basename(inputPath, path.extname(inputPath));
  return path.join(dir, `${name}.summary.md`);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/pipeline/write.test.ts`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/pipeline/write.ts tests/pipeline/write.test.ts
git commit -m "feat: add markdown output writer stage"
```

---

## Chunk 3: Orchestrator, CLI & Integration

### Task 11: Orchestrator

**Files:**
- Create: `src/orchestrator.ts`
- Create: `tests/orchestrator.test.ts`

- [ ] **Step 1: Write failing test**

Create `tests/orchestrator.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { runPipeline } from "../src/orchestrator.js";

describe("orchestrator", () => {
  it("exports runPipeline function", () => {
    expect(runPipeline).toBeDefined();
    expect(typeof runPipeline).toBe("function");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/orchestrator.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement orchestrator**

Create `src/orchestrator.ts`:

```typescript
import path from "node:path";
import ora from "ora";
import type { AppConfig } from "./config.js";
import { OVERLAP_DURATION } from "./constants.js";
import { validateInput } from "./pipeline/validate.js";
import { chunkAudio } from "./pipeline/chunk.js";
import { transcribeChunks } from "./pipeline/transcribe.js";
import { mergeTranscriptions } from "./pipeline/merge.js";
import { summarizeTranscript } from "./pipeline/summarize.js";
import { writeOutput, defaultOutputPath } from "./pipeline/write.js";
import { getAudioDuration } from "./utils/ffmpeg.js";

export interface PipelineOptions {
  inputPath: string;
  outputPath?: string;
  config: AppConfig;
}

function log(verbose: boolean, message: string) {
  if (verbose) {
    const spinner = ora(message).start();
    return spinner;
  }
  return null;
}

export async function runPipeline(options: PipelineOptions): Promise<string> {
  const { inputPath, config } = options;
  const outputPath = options.outputPath ?? defaultOutputPath(inputPath);
  const verbose = config.verbose;

  // 1. Validate
  let spinner = log(verbose, "Validating input...");
  await validateInput(inputPath);
  spinner?.succeed("Input validated");

  // 2. Chunk
  spinner = log(verbose, "Checking if chunking is needed...");
  const chunks = await chunkAudio(inputPath);
  spinner?.succeed(
    chunks.length === 1
      ? "File within size limit, no chunking needed"
      : `Split into ${chunks.length} chunks`
  );

  // 3. Transcribe
  spinner = log(verbose, `Transcribing ${chunks.length} chunk(s)...`);
  const transcriptions = await transcribeChunks(
    chunks,
    config.openaiApiKey,
    config.language
  );
  spinner?.succeed("Transcription complete");

  // 4. Merge
  spinner = log(verbose, "Merging transcripts...");
  const merged = mergeTranscriptions(transcriptions, OVERLAP_DURATION);
  spinner?.succeed("Transcripts merged");

  // 5. Summarize
  spinner = log(verbose, "Summarizing with Claude...");
  const summary = await summarizeTranscript(
    merged.text,
    config.anthropicApiKey,
    config.claudeModel
  );
  spinner?.succeed("Summary generated");

  // 6. Write
  spinner = log(verbose, "Writing output...");
  const duration = await getAudioDuration(inputPath);
  const durationMinutes = Math.round(duration / 60);
  const date = new Date().toISOString().split("T")[0];
  const source = path.basename(inputPath);

  await writeOutput(
    { summary, segments: merged.segments, date, duration: durationMinutes, source },
    outputPath
  );
  spinner?.succeed(`Output written to ${outputPath}`);

  return outputPath;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `npx vitest run tests/orchestrator.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/orchestrator.ts tests/orchestrator.test.ts
git commit -m "feat: add pipeline orchestrator"
```

---

### Task 12: CLI entry point

**Files:**
- Modify: `src/index.ts`
- Create: `tests/index.test.ts`

- [ ] **Step 1: Write failing CLI test**

Create `tests/index.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { execFileSync } from "node:child_process";

describe("CLI", () => {
  it("shows help with --help flag", () => {
    const output = execFileSync("npx", ["tsx", "src/index.ts", "--help"], {
      encoding: "utf-8",
    });
    expect(output).toContain("meetingsum");
    expect(output).toContain("--output");
    expect(output).toContain("--language");
    expect(output).toContain("--model");
    expect(output).toContain("--verbose");
  });

  it("shows version with --version flag", () => {
    const output = execFileSync("npx", ["tsx", "src/index.ts", "--version"], {
      encoding: "utf-8",
    });
    expect(output.trim()).toBe("1.0.0");
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npx vitest run tests/index.test.ts`
Expected: FAIL — CLI not implemented yet

- [ ] **Step 3: Implement CLI**

Replace `src/index.ts` with:

```typescript
#!/usr/bin/env node

import { Command } from "commander";
import { loadConfig } from "./config.js";
import { runPipeline } from "./orchestrator.js";

const program = new Command();

program
  .name("meetingsum")
  .description("Transcribe and summarize meeting audio files")
  .version("1.0.0")
  .argument("<audio-file>", "Path to audio file (.mp3, .wav, .m4a, etc.)")
  .option("-o, --output <path>", "Output file path (default: <input>.summary.md)")
  .option("-l, --language <lang>", "Audio language hint for Whisper")
  .option("-m, --model <model>", "Claude model to use", "claude-sonnet-4-20250514")
  .option("-v, --verbose", "Show progress for each pipeline stage")
  .action(async (audioFile: string, options) => {
    try {
      const config = loadConfig(options);
      const outputPath = await runPipeline({
        inputPath: audioFile,
        outputPath: options.output,
        config,
      });
      console.log(`\nDone! Summary saved to: ${outputPath}`);
    } catch (error) {
      console.error(
        `\nError: ${error instanceof Error ? error.message : String(error)}`
      );
      process.exit(1);
    }
  });

program.parse();
```

- [ ] **Step 4: Verify it compiles**

Run: `npx tsc --noEmit`
Expected: No errors

- [ ] **Step 5: Run CLI tests to verify they pass**

Run: `npx vitest run tests/index.test.ts`
Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add src/index.ts tests/index.test.ts
git commit -m "feat: add CLI entry point with commander"
```

---

### Task 13: Create CLAUDE.md

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Create CLAUDE.md**

Create `CLAUDE.md`:

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MeetingSum is a CLI tool that transcribes audio files using OpenAI Whisper and summarizes them using Claude. It outputs structured markdown with narrative summary, key topics, decisions, and action items.

## Build & Run Commands

- `npm run dev -- <audio-file>` — run in development mode via tsx
- `npm run build` — compile TypeScript to `dist/`
- `npm start -- <audio-file>` — run compiled version
- `npm test` — run all tests (vitest)
- `npm run test:watch` — run tests in watch mode
- `npx vitest run tests/pipeline/validate.test.ts` — run a single test file

## Architecture

Linear pipeline: `Audio → Validate → Chunk → Transcribe → Merge → Summarize → Write`

- **src/index.ts** — CLI entry point (commander). Parses args, calls orchestrator.
- **src/config.ts** — Loads API keys from env vars (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`), merges CLI options.
- **src/orchestrator.ts** — Runs pipeline stages in sequence, handles verbose progress output via ora spinners.
- **src/pipeline/** — One module per pipeline stage. Each exports a single primary function:
  - `validate.ts` — checks file exists, format supported, ffmpeg installed
  - `chunk.ts` — splits audio >20MB into ~10min segments with 30s overlap via ffmpeg
  - `transcribe.ts` — parallel Whisper API calls (max 3 concurrent via p-limit)
  - `merge.ts` — concatenates transcripts, deduplicates overlap regions
  - `summarize.ts` — sends transcript to Claude; for >100k tokens, does section-by-section then roll-up
  - `write.ts` — generates markdown output file
- **src/utils/** — Shared helpers: ffmpeg wrapper, token estimation.

## Key Design Decisions

- Whisper API (not local) to avoid GPU/model download requirements
- 20MB chunking threshold (5MB below Whisper's 25MB limit)
- 30s overlap between audio chunks to avoid losing words at boundaries
- Long transcripts (>100k tokens) are summarized in sections then rolled up
- Output saved as markdown file next to input by default

## External Requirements

- `ffmpeg` and `ffprobe` must be installed and in PATH
- Node.js 18+
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add CLAUDE.md for Claude Code guidance"
```

---

### Task 14: Build and final verification

- [ ] **Step 1: Run full test suite**

Run: `npm test`
Expected: All tests pass

- [ ] **Step 2: Build the project**

Run: `npm run build`
Expected: Compiles to `dist/` without errors

- [ ] **Step 3: Verify CLI help works from compiled output**

Run: `node dist/index.js --help`
Expected: Shows usage with all options

- [ ] **Step 4: Final commit (if any changes needed)**

```bash
git add -A && git status
git commit -m "chore: final build verification"
```
