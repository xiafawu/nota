# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Nota is a TypeScript CLI tool that transcribes and diarizes audio files using AssemblyAI (default) or OpenAI Whisper, then summarizes with GPT-4o. It outputs structured markdown with narrative summary, key topics, decisions, and action items.

## Naming

- Canonical product name: **Nota**
- Canonical CLI command: `nota`
- Canonical share handler: `scripts/nota-share.sh`
- Default share output folder: `~/Documents/Nota`
- Persistent speaker profiles: `~/.nota/speakers.json`
- Legacy `meetingsum` names are compatibility aliases only. Keep `scripts/meetingsum-share.sh`, the `meetingsum` bin alias, `MEETINGSUM_*` env fallbacks, and `~/.meetingsum/speakers.json` fallback unless intentionally doing a breaking cleanup.
- The repository path is `/Users/xiafawu/Developer/Nota`. Treat that as a filesystem location, not the product name.
- `docs/superpowers/` contains historical implementation plans/specs from the old name. Do not use those files as the source of truth for current branding.

## Build & Run Commands

- `npm run dev -- <audio-file>` — run Nota in development mode via tsx
- `npm start -- <audio-file>` — run compiled Nota after `npm run build`
- `npm run build` — compile TypeScript to `dist/`
- `npm test` — run all tests (vitest)
- `npm run test:watch` — run tests in watch mode
- `npx vitest run tests/pipeline/validate.test.ts` — run a single test file

## Architecture

Two pipeline paths controlled by `--provider`:

**AssemblyAI (default):** `Audio → Validate → Transcribe+Diarize (AssemblyAI) → Summarize (GPT-4o) → Write`

**Whisper (fallback):** `Audio → Validate → Chunk → Transcribe (Whisper) + Diarize (pyannote) → Merge → Align → Summarize (GPT-4o) → Write`

- **src/index.ts** — CLI entry point (commander). Parses args, calls orchestrator.
- **src/config.ts** — Loads API keys from env vars, merges CLI options, selects provider.
- **src/constants.ts** — Shared constants: `SEGMENT_DURATION`, `OVERLAP_DURATION`, `CHUNK_THRESHOLD_BYTES`.
- **src/orchestrator.ts** — Branches on `provider` to run AssemblyAI or Whisper pipeline.
- **src/pipeline/** — One module per pipeline stage:
  - `assemblyai.ts` — single API call for transcription + diarization, handles .qta conversion
  - `validate.ts` — checks file exists, format supported, ffmpeg installed
  - `chunk.ts` — splits audio >20MB into ~10min segments with 30s overlap (whisper only)
  - `transcribe.ts` — parallel Whisper API calls, exports `TranscriptSegment` interface (shared)
  - `merge.ts` — concatenates transcripts, deduplicates overlap regions (whisper only)
  - `summarize.ts` — sends transcript to GPT-4o; for >100k tokens, does section-by-section then roll-up
  - `diarize.ts` — calls Python pyannote script, aligns speaker labels (whisper only)
  - `write.ts` — generates markdown output file; header carries **Captured** (recording time from container metadata, fs-birthtime fallback) and **Transcribed** (processing time) dates
- **src/utils/** — Shared helpers: ffmpeg wrapper (`ffmpeg.ts`), token estimation (`tokens.ts`), capture-date resolution (`capture-date.ts`).

## CLI Flags

- `--provider <name>` — `assemblyai` (default) or `whisper`
- `--num-speakers <n>` — expected speaker count (assemblyai only)
- `--no-diarize` — skip pyannote diarization for `--provider whisper`
- `--identify` — identify and remember recurring speakers by voice
- `-o, --output <path>` — output file path
- `-l, --language <lang>` — audio language hint
- `-m, --model <model>` — GPT model for summarization (default: gpt-4o)
- `-v, --verbose` — show progress spinners

## Speaker Management

Manage enrolled speaker voiceprints (`~/.nota/speakers.json`, with legacy
fallback to `~/.meetingsum/speakers.json`):

- `nota speakers list` — print one tab-separated row per profile (name, enrolledAt, source, embedding length) on stdout
- `nota speakers show <name>` — print profile JSON with embedding truncated to first 8 dims
- `nota speakers rename <old> <new>` — rename a profile key
- `nota speakers delete <name>` — remove a profile
- `nota speakers merge <src> <dst>` — average embeddings (L2-renormalized) into `<dst>`, drop `<src>`

Commands exit non-zero if a referenced profile is missing. Confirmation lines
are written to stderr so stdout stays scriptable.

## Key Design Decisions

- Nota is the primary name; MeetingSum references exist only for backward compatibility.
- AssemblyAI as default provider: transcription + diarization in one API call ($0.15/hr)
- Whisper retained as fallback via `--provider whisper`
- `.qta` files auto-converted to `.m4a` via ffmpeg before AssemblyAI upload
- Optional `--identify` stores speaker voiceprints in `~/.nota/speakers.json`; existing `~/.meetingsum/speakers.json` profiles are still read as a fallback
- Long transcripts (>100k tokens) are summarized in sections then rolled up
- Output saved as markdown file next to input by default
- ESM-only project (`"type": "module"` in package.json)

## External Requirements

- `ffmpeg` and `ffprobe` must be installed and in PATH
- Node.js 18+
- Environment variable: `OPENAI_API_KEY` (always required for GPT-4o summarization)
- Environment variable: `ASSEMBLYAI_API_KEY` (required for default assemblyai provider)
- For `--provider whisper` only: Python 3.8+ with `pyannote.audio`, `HUGGINGFACE_TOKEN`
