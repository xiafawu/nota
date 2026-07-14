import { describe, expect, it } from "vitest";

import {
  assertCosineValidation,
  parseArgs,
} from "../../scripts/validate-embed.js";
import { kaldiFbank } from "../../src/pipeline/embed.js";

describe("validation-harness arguments", () => {
  it("requires a Python reference before a run can report full validation", () => {
    expect(() =>
      parseArgs([
        "--model",
        "model.onnx",
        "--same-a",
        "same-a.wav",
        "--same-b",
        "same-b.wav",
        "--different",
        "different.wav",
      ]),
    ).toThrow(/--reference-python/);
  });
});

describe("validation-harness cosine gates", () => {
  it("rejects a same-speaker score below the operational MATCH threshold", () => {
    expect(() => assertCosineValidation(0.49, 0.2, 0.2)).toThrow(/MATCH.*0\.50/);
  });

  it("requires both different-speaker scores below the TENTATIVE threshold", () => {
    expect(() => assertCosineValidation(0.8, 0.35, 0.2)).toThrow(
      /TENTATIVE.*0\.35/,
    );
    expect(() => assertCosineValidation(0.8, 0.2, 0.35)).toThrow(
      /TENTATIVE.*0\.35/,
    );
  });
});

describe("validation-harness Kaldi fbank", () => {
  it("uses 25 ms frames, 10 ms hops, 80 mel bins, and utterance CMN", () => {
    const pcm = new Int16Array(16_000);
    for (let i = 0; i < pcm.length; i++) {
      pcm[i] = Math.round(10_000 * Math.sin((2 * Math.PI * 220 * i) / 16_000));
    }

    const { data, frames, bins } = kaldiFbank(pcm);

    expect(frames).toBe(98);
    expect(bins).toBe(80);
    expect(data).toHaveLength(frames * bins);
    for (let bin = 0; bin < bins; bin++) {
      let mean = 0;
      for (let frame = 0; frame < frames; frame++) {
        mean += data[frame * bins + bin];
      }
      expect(mean / frames).toBeCloseTo(0, 5);
    }
  });
});
