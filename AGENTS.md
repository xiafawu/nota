# AGENTS.md

Instructions for AI agents working with this codebase.

## Naming

- Canonical product name: **Nota**
- Canonical CLI command: `nota`
- Canonical share handler: `scripts/nota-share.sh`
- Default share output folder: `~/Documents/Nota`
- Persistent speaker profiles: `~/.nota/speakers.json`
- Legacy MeetingSum identifiers are compatibility aliases only. Preserve `scripts/meetingsum-share.sh`, the `meetingsum` bin alias, `MEETINGSUM_*` env fallbacks, and `~/.meetingsum/speakers.json` fallback unless intentionally doing a breaking cleanup.
- The repository path is `/Users/xiafawu/Developer/Nota`; treat that as a filesystem location, not the product name.
- `docs/superpowers/` contains historical implementation plans/specs from the old name. Do not use those files as the source of truth for current branding.

## Quick Start — Running Nota

```bash
# Basic usage (AssemblyAI transcription + diarization by default)
npm run dev -- <audio-file> -v

# With explicit output path
npm run dev -- <audio-file> -v -o output.md

# Remember recurring speakers by voice
PYTHON_BIN=python3.11 npm run dev -- <audio-file> -v --identify

# Whisper fallback with pyannote diarization
PYTHON_BIN=python3.11 npm run dev -- <audio-file> -v --provider whisper

# Whisper fallback without pyannote diarization
npm run dev -- <audio-file> -v --provider whisper --no-diarize
```

## Required Environment Variables

| Variable | Required | Purpose |
|---|---|---|
| `OPENAI_API_KEY` | Always | GPT-4o summarization; Whisper transcription when `--provider whisper` |
| `ASSEMBLYAI_API_KEY` | Default provider | AssemblyAI transcription + diarization |
| `HUGGINGFACE_TOKEN` | Whisper diarization or `--identify` | pyannote.audio model access (gated models) |
| `PYTHON_BIN` | If python3 != 3.11 for pyannote flows | Path to Python with pyannote installed (default: `python3`) |

## Common Pitfalls

### AssemblyAI is the default provider
Running without `--provider` uses AssemblyAI, so `ASSEMBLYAI_API_KEY` must be set. Use `--provider whisper` to use OpenAI Whisper instead.

### Python version mismatch
The owner's system has `python3` → Python 3.14 but pyannote is installed under `python3.11`. Always set `PYTHON_BIN=python3.11` when running `--provider whisper` with diarization or when using `--identify`.

### HuggingFace gated model access
The pyannote flows require accepting licenses for gated models on huggingface.co:
1. `pyannote/speaker-diarization-3.1`
2. `pyannote/segmentation-3.0`
3. `pyannote/speaker-diarization-community-1`
4. `pyannote/embedding`

Fine-grained HuggingFace tokens also need the **"Access public gated repos"** permission enabled.

### Voice Memos files
macOS Voice Memos temp paths (`.com.apple.uikit.itemprovider.temporary.*`) are ephemeral — they disappear when the share sheet closes. Copy files to `audio/` before processing. The `audio/` directory is gitignored.

### Supported audio formats
`.mp3`, `.wav`, `.m4a`, `.aac`, `.caf`, `.aif`, `.aiff`, `.ogg`, `.webm`, `.flac`, `.qta`, `.mov`, `.mp4`

## Architecture

Default AssemblyAI path:

```
Audio File
  → Validate (file exists, format ok, ffmpeg present)
  → Transcribe + diarize speakers (AssemblyAI)
  → Optionally identify recurring speakers by voice (--identify)
  → Summarize (GPT-4o, section-by-section for >100k tokens)
  → Write markdown output
```

Whisper fallback path:

```
Audio File
  → Validate (file exists, format ok, ffmpeg present)
  → Chunk (split >20MB files into ~10min segments with 30s overlap)
  → [parallel] Transcribe chunks (Whisper API, 3 concurrent)
  → [parallel] Diarize speakers (pyannote.audio via Python subprocess)
  → Merge transcripts (deduplicate overlap regions)
  → Align speaker labels (match by maximum time overlap)
  → Summarize (GPT-4o, section-by-section for >100k tokens)
  → Write markdown output
```

### Key files

| File | Responsibility |
|---|---|
| `src/index.ts` | CLI entry point (commander) |
| `src/orchestrator.ts` | Pipeline orchestration |
| `src/config.ts` | Config loading, env var validation |
| `src/pipeline/validate.ts` | Input validation, Python/ffmpeg checks |
| `src/pipeline/assemblyai.ts` | AssemblyAI transcription + diarization |
| `src/pipeline/chunk.ts` | Audio chunking via ffmpeg for Whisper |
| `src/pipeline/transcribe.ts` | Whisper API calls (parallel via p-limit) |
| `src/pipeline/diarize.ts` | Spawns Python subprocess, aligns speakers |
| `src/pipeline/merge.ts` | Transcript merging with overlap dedup |
| `src/pipeline/speakers.ts` | Persistent speaker voiceprint matching |
| `src/pipeline/summarize.ts` | GPT-4o summarization with speaker awareness |
| `src/pipeline/write.ts` | Markdown output generation |
| `scripts/diarize.py` | Python script for pyannote speaker diarization |
| `scripts/embeddings.py` | Python script for pyannote speaker embeddings |
| `scripts/nota-share.sh` | macOS Shortcuts/Automator share handler |
| `scripts/meetingsum-share.sh` | Backward-compatible wrapper for existing shortcuts |

### Testing

```bash
npm test                # run all tests (vitest)
npm run test:watch      # watch mode
npx vitest run tests/pipeline/validate.test.ts  # single file
```

Tests use vitest. No mocking of external services needed for unit tests — the test suite covers pure logic (merging, alignment, config, validation).

## Coding Conventions

- ESM-only (`"type": "module"` in package.json) — use `.js` extensions in imports
- One pipeline stage per file in `src/pipeline/`
- Each pipeline module exports a single primary function
- TypeScript strict mode
- No default exports — use named exports
