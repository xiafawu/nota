# Nota

Transcribe, diarize, and summarize audio into structured meeting notes — from the command line, with an optional macOS dictation app.

Nota takes an audio file (meeting recording, voice memo, interview), transcribes it with speaker labels, and produces a markdown file with a narrative summary, key topics, decisions, and action items.

```bash
nota meeting.m4a
# → meeting.md next to the input, with summary + speaker-labeled sections
```

## Requirements

- **Node.js 18+**
- **ffmpeg** and **ffprobe** on `PATH` (`brew install ffmpeg`)
- API keys (bring your own — nothing is bundled):

| Key | Needed for | Notes |
|-----|------------|-------|
| `ASSEMBLYAI_API_KEY` | Transcription + diarization (default path) | ~$0.15/hr of audio |
| `DEEPSEEK_API_KEY` | Summaries via DeepSeek | Cheapest default, picked first if set |
| `OPENAI_API_KEY` | Summaries via GPT, or `--provider whisper` transcription | |
| `GEMINI_API_KEY` | Summaries via Gemini | |

You need `ASSEMBLYAI_API_KEY` plus **any one** of the three summary keys.

## Install

```bash
git clone https://github.com/xiafawu/nota.git
cd nota
npm install
npm run build
npm link        # puts `nota` on your PATH
```

## API keys

Put keys in `~/.nota/config` (dotenv format, one `KEY=VALUE` per line):

```bash
mkdir -p ~/.nota
cat > ~/.nota/config <<'EOF'
ASSEMBLYAI_API_KEY=your-key-here
DEEPSEEK_API_KEY=your-key-here
EOF
chmod 600 ~/.nota/config
```

Real environment variables override file values. Verify what resolves (values are masked, never printed):

```bash
nota config
```

Keys live only in `~/.nota/config` or your environment — never in this repository.

## Usage

```bash
nota recording.m4a                 # transcribe + diarize + summarize
nota recording.m4a -v              # with progress spinners
nota recording.m4a --identify      # recognize enrolled speakers by voice
nota recording.m4a -m gpt-5-mini   # pick the summary model
nota recording.m4a --num-speakers 3
nota recording.m4a -o notes.md
```

Useful verbs:

```bash
nota models list        # available summary models (auto-refreshed weekly from models.dev)
nota settings list      # effective model choices and where they came from
nota speakers list      # enrolled speaker voiceprints
nota dictionary list    # custom vocabulary shared with the dictation app
```

Re-running the same file reuses the previous result instead of paying for transcription again (`--force` overrides).

Speaker identification is pure Node (ONNX voice embeddings) — no Python, no extra API key. The model is downloaded and checksum-verified on first use.

## macOS dictation app (optional)

A SwiftUI menu-bar app with system-wide dictation: hold a hotkey, speak, and polished text lands at your cursor. Includes streaming delivery, a review-before-insert mode, and a custom dictionary that also biases the recognizer.

Requires **macOS 26+ and Xcode 26+**, plus `xcodegen` (`brew install xcodegen`):

```bash
npm run build:macos     # builds .build/macos-app/Nota.app
npm run deploy:macos    # installs to /Applications
```

Grant microphone, speech recognition, and Accessibility permissions when prompted. See [docs/macos-app.md](docs/macos-app.md).

## Building and running with an AI agent

This repo is set up for coding agents (Claude Code and similar):

- **[CLAUDE.md](CLAUDE.md)** — full architecture, pipeline stages, CLI flags, and design decisions. Claude Code loads it automatically; point other agents at it.
- **[AGENTS.md](AGENTS.md)** — agent-facing quick start and naming rules.
- **[CONTEXT.md](CONTEXT.md)** — domain glossary.

The fastest path for a friend with Claude Code:

```bash
git clone https://github.com/xiafawu/nota.git && cd nota && claude
# then: "set this up and transcribe ~/Downloads/meeting.m4a"
```

Verification commands agents can rely on: `npm test` (vitest), `npm run build` (tsc), `nota config` (key resolution), `npx vitest run tests/<file>` (single test file).

`docs/`, `.eval-loop/`, and `.claude/` contain historical planning artifacts — useful context, but `CLAUDE.md` is the source of truth.

## License

[MIT](LICENSE)
