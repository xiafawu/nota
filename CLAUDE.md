# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MeetingSum is a TypeScript CLI tool that transcribes audio files using OpenAI Whisper and summarizes them using GPT-4o. It outputs structured markdown with narrative summary, key topics, decisions, and action items. Only requires a single OpenAI API key.

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
- **src/config.ts** — Loads API key from env var (`OPENAI_API_KEY`), merges CLI options.
- **src/constants.ts** — Shared constants: `SEGMENT_DURATION`, `OVERLAP_DURATION`, `CHUNK_THRESHOLD_BYTES`.
- **src/orchestrator.ts** — Runs pipeline stages in sequence, handles verbose progress output via ora spinners.
- **src/pipeline/** — One module per pipeline stage. Each exports a single primary function:
  - `validate.ts` — checks file exists, format supported, ffmpeg installed
  - `chunk.ts` — splits audio >20MB into ~10min segments with 30s overlap via ffmpeg
  - `transcribe.ts` — parallel Whisper API calls (max 3 concurrent via p-limit)
  - `merge.ts` — concatenates transcripts, deduplicates overlap regions by timestamp filtering
  - `summarize.ts` — sends transcript to GPT-4o; for >100k tokens, does section-by-section then roll-up
  - `write.ts` — generates markdown output file
- **src/utils/** — Shared helpers: ffmpeg wrapper (`ffmpeg.ts`), token estimation (`tokens.ts`).

## Key Design Decisions

- Whisper API (not local) to avoid GPU/model download requirements
- 20MB chunking threshold (5MB below Whisper's 25MB limit)
- 30s overlap between audio chunks to avoid losing words at boundaries
- Long transcripts (>100k tokens) are summarized in sections then rolled up
- Output saved as markdown file next to input by default
- ESM-only project (`"type": "module"` in package.json)

## External Requirements

- `ffmpeg` and `ffprobe` must be installed and in PATH
- Node.js 18+
- Environment variable: `OPENAI_API_KEY`
