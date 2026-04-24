#!/usr/bin/env python3
"""Extract speaker embeddings from audio using pyannote. Reads JSON from stdin, writes JSON to stdout."""

import json
import os
import sys


def main():
    data = json.load(sys.stdin)
    audio_path = data["audio"]
    speakers = data["speakers"]  # {"Speaker 1": [{"start": 0.0, "end": 5.0}, ...], ...}

    try:
        from pyannote.audio import Model, Inference
        from pyannote.core import Segment
        import numpy as np
    except ImportError as e:
        print(f"Missing dependency: {e}. Run: pip install pyannote.audio torch numpy", file=sys.stderr)
        sys.exit(1)

    token = os.environ.get("HUGGINGFACE_TOKEN")

    try:
        model = Model.from_pretrained("pyannote/embedding", token=token)
        inference = Inference(model, window="whole")
    except Exception as e:
        print(f"Failed to load embedding model: {e}", file=sys.stderr)
        sys.exit(1)

    results = {}
    for label, segs in speakers.items():
        embeddings = []
        # Use up to 5 longest segments (>= 1.5s) for robust embedding
        valid_segs = [s for s in segs if s["end"] - s["start"] >= 1.5]
        valid_segs.sort(key=lambda s: s["end"] - s["start"], reverse=True)

        for seg in valid_segs[:5]:
            try:
                emb = inference.crop(audio_path, Segment(seg["start"], seg["end"]))
                if emb.ndim > 1:
                    emb = np.mean(emb, axis=0)
                embeddings.append(emb)
            except Exception:
                continue

        if embeddings:
            mean_emb = np.mean(np.stack(embeddings), axis=0)
            norm = np.linalg.norm(mean_emb)
            if norm > 0:
                mean_emb = mean_emb / norm
            results[label] = mean_emb.tolist()

    json.dump(results, sys.stdout)


if __name__ == "__main__":
    main()
