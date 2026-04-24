#!/bin/bash
# MeetingSum Share handler — receives audio file, transcribes, summarizes.
# Designed to be called from macOS Shortcuts or Automator.

set -euo pipefail

# Load environment variables (API keys)
source ~/.zshrc 2>/dev/null || true

# Use python3.11 for pyannote embeddings
export PYTHON_BIN="${PYTHON_BIN:-python3.11}"

INPUT="$1"
if [ -z "$INPUT" ] || [ ! -f "$INPUT" ]; then
  osascript -e 'display notification "No audio file provided" with title "MeetingSum" sound name "Basso"'
  exit 1
fi

# Output directory
OUTPUT_DIR="$HOME/Documents/MeetingSum"
mkdir -p "$OUTPUT_DIR"

# Generate output filename from input name + timestamp
BASENAME=$(basename "$INPUT" | sed 's/\.[^.]*$//')
TIMESTAMP=$(date +%Y%m%d-%H%M)
OUTPUT="$OUTPUT_DIR/${BASENAME}-${TIMESTAMP}.summary.md"

# Copy input to stable location immediately (Voice Memos temp files vanish)
STABLE_COPY=$(mktemp -t meetingsum-input).m4a
cp "$INPUT" "$STABLE_COPY"

osascript -e 'display notification "Transcribing and summarizing..." with title "MeetingSum"'

# Run pipeline
cd /Users/xiafawu/Developer/MeetingSum
if npm run dev -- "$STABLE_COPY" --identify -o "$OUTPUT" 2>/tmp/meetingsum-error.log; then
  osascript -e "display notification \"Summary saved!\" with title \"MeetingSum\" sound name \"Glass\""
  open "$OUTPUT"
else
  ERROR=$(tail -1 /tmp/meetingsum-error.log)
  osascript -e "display notification \"Failed: $ERROR\" with title \"MeetingSum\" sound name \"Basso\""
fi

# Cleanup
rm -f "$STABLE_COPY"
