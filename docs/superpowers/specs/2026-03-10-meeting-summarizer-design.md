# Meeting Transcriber & Summarizer — Design Spec

## Overview

A CLI tool (`meetingsum`) that takes an audio file of a meeting, transcribes it using OpenAI Whisper, and produces a structured + narrative summary using Claude. Output is a markdown file.

## CLI Interface

```
meetingsum <audio-file> [options]

Options:
  --output, -o <path>    Output file path (default: <input-name>.summary.md)
  --language, -l <lang>  Audio language hint for Whisper (default: auto-detect)
  --model, -m <model>    Claude model to use (default: claude-sonnet-4-20250514)
  --verbose, -v          Show progress for each pipeline stage
```

- Supported input formats: anything ffmpeg can decode (.mp3, .wav, .m4a, .ogg, .webm, .flac)
- API keys via environment variables: `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`

## Architecture: Linear Pipeline

```
Audio File → Validate → Chunk → Transcribe → Merge → Summarize → Write
```

### Validate
- Check file exists and format is supported
- Verify ffmpeg is installed
- Validate API keys are set

### Chunk
- If file > 20MB, split into ~10-minute segments via ffmpeg
- 30-second overlap between chunks to avoid cutting mid-sentence
- Files under 20MB are passed through as a single chunk

### Transcribe
- Send chunks to Whisper API in parallel (max 3 concurrent via p-limit)
- Returns timestamped text per chunk

### Merge
- Concatenate transcripts from all chunks
- Deduplicate overlap regions using fuzzy string matching

### Summarize
- Send full transcript to Claude with a structured prompt
- For very long transcripts (>100k tokens): split into sections, summarize each, then produce a final roll-up summary
- Produces both structured metadata and narrative summary

### Write
- Save markdown file with summary + full transcript

## Output Format

```markdown
# Meeting Summary

**Date:** YYYY-MM-DD
**Duration:** X minutes
**Source:** filename.mp3

## Summary
Narrative paragraph recap.

## Key Topics
- **Topic** — description

## Decisions Made
- Decision — context

## Action Items
- [ ] Action item — assigned to Person

---

## Full Transcript
[00:00] Speaker 1: text...
```

- Duration from ffmpeg audio metadata
- Speaker labels are best-effort from Whisper segment breaks (no diarization)
- Action items use markdown checkboxes

## Project Structure

```
MeetingSum/
├── package.json
├── tsconfig.json
├── CLAUDE.md
├── src/
│   ├── index.ts              # CLI entry point (commander)
│   ├── config.ts             # API key validation, defaults
│   ├── pipeline/
│   │   ├── validate.ts       # File/format/ffmpeg checks
│   │   ├── chunk.ts          # Audio splitting via ffmpeg
│   │   ├── transcribe.ts     # Whisper API calls (parallel)
│   │   ├── merge.ts          # Transcript concat + dedup
│   │   ├── summarize.ts      # Claude API summarization
│   │   └── write.ts          # Markdown file generation
│   ├── orchestrator.ts       # Pipeline sequencer
│   └── utils/
│       ├── ffmpeg.ts         # ffmpeg child process wrapper
│       ├── audio.ts          # Duration, format detection
│       └── tokens.ts         # Token counting for chunking
├── tests/
│   ├── pipeline/             # Unit tests per stage
│   └── fixtures/             # Small test audio files
└── dist/
```

## Dependencies

**Runtime:** commander, openai, @anthropic-ai/sdk, p-limit, ora
**Dev:** typescript, tsx, vitest, eslint, prettier
**System:** ffmpeg (must be installed)

## Decisions

- **Approach A (simple pipeline)** chosen over streaming pipeline or local Whisper for simplicity and speed of development
- **Whisper API** over local Whisper to avoid GPU/model download requirements
- **Claude** for summarization due to strong structured output capabilities
- **20MB chunking threshold** leaves 5MB margin below Whisper's 25MB limit
- **30s overlap** balances dedup accuracy vs. redundant API cost
