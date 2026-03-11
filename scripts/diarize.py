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
    if not os.path.isfile(audio_path):
        print(f"Audio file not found: {audio_path}", file=sys.stderr)
        sys.exit(1)

    token = os.environ.get("HUGGINGFACE_TOKEN")
    if not token:
        print("HUGGINGFACE_TOKEN environment variable is required", file=sys.stderr)
        sys.exit(1)

    try:
        from pyannote.audio import Pipeline
    except ImportError:
        print("pyannote.audio is not installed. Run: pip install pyannote.audio torch", file=sys.stderr)
        sys.exit(1)

    try:
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            token=token,
        )
    except Exception as e:
        print(f"Failed to load diarization model: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        diarization = pipeline(audio_path)
    except Exception as e:
        print(f"Diarization failed: {e}", file=sys.stderr)
        sys.exit(1)

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
