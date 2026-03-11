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
    token = os.environ.get("HUGGINGFACE_TOKEN")
    if not token:
        print("HUGGINGFACE_TOKEN environment variable is required", file=sys.stderr)
        sys.exit(1)

    try:
        from pyannote.audio import Pipeline
    except ImportError:
        print("pyannote.audio is not installed. Run: pip install pyannote.audio torch", file=sys.stderr)
        sys.exit(1)

    pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=token,
    )

    diarization = pipeline(audio_path)

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
