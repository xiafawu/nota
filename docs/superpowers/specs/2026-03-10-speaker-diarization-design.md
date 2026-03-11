# Speaker Diarization Design Spec

## Overview

Add speaker identification to MeetingSum using pyannote.audio. Diarization is enabled by default and can be disabled with `--no-diarize`. Speakers are labeled in the transcript and provided to the summarizer for attribution.

## Pipeline Change

```
Audio → Validate → Chunk ──────────────┐
                    │                   │
                    └→ Diarize (parallel)│
                                        ↓
                              Transcribe → Align Speakers → Merge → Summarize → Write
```

- Diarization runs on the **original full audio file** (not chunks) for consistent speaker tracking
- Diarization and chunked transcription run in **parallel** since they're independent
- After both complete, speaker labels are aligned with Whisper segments by timestamp overlap

## Python Script: `scripts/diarize.py`

- Takes audio file path as CLI argument
- Reads `HUGGINGFACE_TOKEN` from environment
- Runs `pyannote/speaker-diarization-3.1` pipeline
- Outputs JSON array to stdout:
  ```json
  [
    {"start": 0.5, "end": 3.2, "speaker": "SPEAKER_00"},
    {"start": 3.5, "end": 8.1, "speaker": "SPEAKER_01"}
  ]
  ```
- Exits non-zero with error message to stderr on failure

### Python Dependencies

```
pyannote.audio
torch
```

Users install via: `pip install pyannote.audio torch`

## New Module: `src/pipeline/diarize.ts`

### `runDiarization(audioPath: string): Promise<DiarizationSegment[]>`
- Spawns `python3 scripts/diarize.py <audioPath>` via `child_process.execFile`
- Parses JSON stdout into `DiarizationSegment[]`
- Throws on non-zero exit or invalid JSON

### `alignSpeakers(segments: TranscriptSegment[], diarization: DiarizationSegment[]): TranscriptSegment[]`
- For each transcript segment, finds the diarization segment with maximum time overlap
- Assigns the matching speaker label to the transcript segment's new `speaker` field
- If no diarization segment overlaps, leaves `speaker` undefined

### Types
```typescript
interface DiarizationSegment {
  start: number;
  end: number;
  speaker: string;
}
```

## Changes to Existing Modules

### `TranscriptSegment` (transcribe.ts)
Add optional `speaker` field:
```typescript
export interface TranscriptSegment {
  start: number;
  end: number;
  text: string;
  speaker?: string;
}
```

### Validate (validate.ts)
When diarization is enabled, additionally check:
- `python3` is available in PATH
- `HUGGINGFACE_TOKEN` environment variable is set

### Orchestrator (orchestrator.ts)
- Accept `diarize: boolean` in `PipelineOptions`
- Run diarization in parallel with transcription using `Promise.all`
- After both complete, call `alignSpeakers` to merge results
- Pass aligned segments through the rest of the pipeline

### Write (write.ts)
Transcript lines include speaker labels when present:
```
[05:23] **Speaker 1:** We should finalize the budget...
[05:45] **Speaker 2:** I agree, let's set the deadline...
```
Speaker labels are humanized: `SPEAKER_00` → `Speaker 1`, `SPEAKER_01` → `Speaker 2`.

### Summarize (summarize.ts)
`buildSummaryPrompt` includes speaker-labeled transcript so GPT can attribute decisions and action items to specific speakers.

### Config (config.ts)
Add `diarize: boolean` to `AppConfig`, defaulting to `true`.

### CLI (index.ts)
Add `--no-diarize` flag:
```typescript
.option("--no-diarize", "Skip speaker identification")
```

## Environment Requirements

When diarization is enabled:
- Python 3.8+ with `pyannote.audio` and `torch` installed
- `HUGGINGFACE_TOKEN` environment variable set
- HuggingFace account with accepted license for `pyannote/speaker-diarization-3.1`

## Error Handling

- If Python/pyannote is not installed and `--no-diarize` is not set, fail at validate step with a clear message explaining what to install
- If diarization fails at runtime, fail the pipeline (don't silently skip — user expects speaker labels)
