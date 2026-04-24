# Nota Share Sheet Setup

Use this to send audio from Voice Memos, Apple Notes attachments, Finder, or other macOS share-sheet sources into Nota.

## Prerequisites

- `OPENAI_API_KEY` must be available to non-interactive shells.
- `ASSEMBLYAI_API_KEY` must be available unless you set `NOTA_SHARE_FLAGS` to use Whisper.
- `ffmpeg` and `ffprobe` must be on `PATH`.
- For recurring speaker identification, set `PYTHON_BIN=python3.11` and `HUGGINGFACE_TOKEN`.

The share handler loads `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, and `~/.bash_profile`, so putting exports in `~/.zshenv` is the most reliable option for Shortcuts.

```bash
export OPENAI_API_KEY="..."
export ASSEMBLYAI_API_KEY="..."
export HUGGINGFACE_TOKEN="..."
export PYTHON_BIN="python3.11"
```

## Create the Shortcut

1. Open **Shortcuts** on macOS.
2. Create a new shortcut named `Nota`.
3. Open the shortcut details and enable **Use as Quick Action** and **Services Menu**.
4. Set **Receive** to **Files** and **Media** in **Any Application**.
5. Add a **Run Shell Script** action.
6. Set **Shell** to `/bin/bash`.
7. Set **Pass Input** to **as arguments**.
8. Use this script:

```bash
/Users/xiafawu/Developer/Nota/scripts/nota-share.sh "$@"
```

## Use It

- Voice Memos: select a recording, choose Share, then run `Nota`.
- Apple Notes: share an audio attachment from the note, then run `Nota`.
- Finder: right-click an audio file, then choose Quick Actions or Services > `Nota`.
- Shortcuts editor: pressing the play button with no shared input opens a file picker for testing.

Summaries are written to `~/Documents/Nota`.

## Optional Share Defaults

By default, the share handler runs with `--identify`. Override that by setting `NOTA_SHARE_FLAGS`.

```bash
export NOTA_SHARE_FLAGS="-v"
export NOTA_SHARE_FLAGS="-v --provider whisper --no-diarize"
```

The legacy `MEETINGSUM_SHARE_FLAGS` variable is still supported during the rename.

For Notes, share the audio attachment itself. Sharing plain note text is not transcribed because Nota expects an audio or media file.
