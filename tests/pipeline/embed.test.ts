import { beforeEach, describe, expect, it, vi } from "vitest";

const runtimeMocks = vi.hoisted(() => ({
  createSession: vi.fn(),
  resolveModel: vi.fn(),
}));

vi.mock("onnxruntime-node", () => ({
  InferenceSession: { create: runtimeMocks.createSession },
  Tensor: class MockTensor {
    constructor(
      public readonly type: string,
      public readonly data: Float32Array,
      public readonly dims: number[],
    ) {}
  },
}));

vi.mock("../../src/utils/model.js", () => ({
  resolveModel: runtimeMocks.resolveModel,
}));

import {
  computeEmbedding,
  computeEmbeddings,
  cosine,
  InsufficientSpeechError,
  kaldiFbank,
  MATCH_THRESHOLD,
  MODEL_SPEC,
  TENTATIVE_THRESHOLD,
} from "../../src/pipeline/embed.js";

describe("cosine", () => {
  it("computes vector similarity and rejects invalid dimensions", () => {
    expect(cosine([1, 0], [1, 0])).toBe(1);
    expect(cosine([1, 0], [0, 1])).toBe(0);
    expect(() => cosine([1, 2], [1])).toThrow(/dimensions/);
  });

  it("rejects empty, zero, and non-finite vectors", () => {
    expect(() => cosine([], [])).toThrow(/dimensions/);
    expect(() => cosine([0, 0], [1, 0])).toThrow(/zero/);
    expect(() => cosine([Number.POSITIVE_INFINITY], [1])).toThrow(/finite/);
    expect(() => cosine([Number.NaN], [1])).toThrow(/finite/);
  });
});

describe("kaldiFbank", () => {
  it("uses the validated frame geometry and utterance CMN", () => {
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

describe("computeEmbedding", () => {
  it("rejects clips too short for one feature frame without loading a model", async () => {
    await expect(computeEmbedding(new Int16Array(399))).rejects.toBeInstanceOf(
      InsufficientSpeechError,
    );
  });

  it("omits insufficient clips in a batch without resolving the model", async () => {
    await expect(
      computeEmbeddings({
        SPEAKER_00: new Int16Array(399),
        SPEAKER_01: new Int16Array(),
      }),
    ).resolves.toEqual({});
  });
});

describe("ONNX inference", () => {
  beforeEach(() => {
    vi.resetModules();
    runtimeMocks.createSession.mockReset();
    runtimeMocks.resolveModel.mockReset();
    runtimeMocks.resolveModel.mockResolvedValue("/models/wespeaker.onnx");
  });

  it("runs the model with [1,T,80] features and L2-normalizes a [1,256] output", async () => {
    const raw = new Float32Array(256);
    raw[0] = 3;
    raw[1] = 4;
    const run = vi.fn().mockResolvedValue({
      embs: { data: raw, dims: [1, 256] },
    });
    runtimeMocks.createSession.mockResolvedValue({ run });
    const { computeEmbedding } = await import("../../src/pipeline/embed.js");

    const embedding = await computeEmbedding(new Int16Array(400).fill(100));

    expect(embedding).toHaveLength(256);
    expect(embedding[0]).toBeCloseTo(0.6);
    expect(embedding[1]).toBeCloseTo(0.8);
    expect(run).toHaveBeenCalledOnce();
    const feeds = run.mock.calls[0][0];
    expect(feeds.feats.dims).toEqual([1, 1, 80]);
    expect(runtimeMocks.resolveModel).toHaveBeenCalledOnce();
    expect(runtimeMocks.createSession).toHaveBeenCalledWith(
      "/models/wespeaker.onnx",
    );
  });

  it("reuses one cached session while embedding multiple labels", async () => {
    const run = vi.fn().mockResolvedValue({
      embs: { data: new Float32Array(256).fill(1), dims: [1, 256] },
    });
    runtimeMocks.createSession.mockResolvedValue({ run });
    const { computeEmbeddings } = await import("../../src/pipeline/embed.js");

    const embeddings = await computeEmbeddings({
      SPEAKER_00: new Int16Array(400).fill(100),
      SPEAKER_01: new Int16Array(400).fill(200),
    });

    expect(Object.keys(embeddings)).toEqual(["SPEAKER_00", "SPEAKER_01"]);
    expect(runtimeMocks.resolveModel).toHaveBeenCalledOnce();
    expect(runtimeMocks.createSession).toHaveBeenCalledOnce();
    expect(run).toHaveBeenCalledTimes(2);
  });

  it("retries session loading after an availability check fails", async () => {
    runtimeMocks.resolveModel
      .mockRejectedValueOnce(new Error("offline"))
      .mockResolvedValueOnce("/models/wespeaker.onnx");
    runtimeMocks.createSession.mockResolvedValue({ run: vi.fn() });
    const { isIdentityAvailable } = await import(
      "../../src/pipeline/embed.js"
    );

    await expect(isIdentityAvailable()).resolves.toBe(false);
    await expect(isIdentityAvailable()).resolves.toBe(true);
    expect(runtimeMocks.resolveModel).toHaveBeenCalledTimes(2);
    expect(runtimeMocks.createSession).toHaveBeenCalledOnce();
  });

  it("retries after native session creation fails", async () => {
    runtimeMocks.createSession
      .mockRejectedValueOnce(new Error("native create failed"))
      .mockResolvedValueOnce({ run: vi.fn() });
    const { isIdentityAvailable } = await import(
      "../../src/pipeline/embed.js"
    );

    await expect(isIdentityAvailable()).resolves.toBe(false);
    await expect(isIdentityAvailable()).resolves.toBe(true);
    expect(runtimeMocks.resolveModel).toHaveBeenCalledTimes(2);
    expect(runtimeMocks.createSession).toHaveBeenCalledTimes(2);
  });

  it("rejects an output whose data length is 256 but shape is not [1,256]", async () => {
    runtimeMocks.createSession.mockResolvedValue({
      run: vi.fn().mockResolvedValue({
        embs: { data: new Float32Array(256).fill(1), dims: [256] },
      }),
    });
    const { computeEmbedding } = await import("../../src/pipeline/embed.js");

    await expect(computeEmbedding(new Int16Array(400))).rejects.toThrow(
      /embs\[1,256\]/,
    );
  });

  it("rethrows non-speech errors from batched inference", async () => {
    const inferenceError = new Error("inference failed");
    runtimeMocks.createSession.mockResolvedValue({
      run: vi.fn().mockRejectedValue(inferenceError),
    });
    const { computeEmbeddings } = await import("../../src/pipeline/embed.js");

    await expect(
      computeEmbeddings({ SPEAKER_00: new Int16Array(400).fill(100) }),
    ).rejects.toBe(inferenceError);
  });

  it("turns a native runtime import failure into unavailable instead of crashing module import", async () => {
    vi.resetModules();
    vi.doMock("onnxruntime-node", () => {
      throw new Error("native runtime failed to load");
    });

    const { isIdentityAvailable } = await import(
      "../../src/pipeline/embed.js"
    );
    await expect(isIdentityAvailable()).resolves.toBe(false);
  });
});

describe("speaker model configuration", () => {
  it("exposes the validation-calibrated model and thresholds", () => {
    expect(MATCH_THRESHOLD).toBe(0.5);
    expect(TENTATIVE_THRESHOLD).toBe(0.35);
    expect(MODEL_SPEC).toEqual({
      name: "wespeaker_en_voxceleb_resnet34_LM.onnx",
      url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx",
      sha256:
        "e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012",
    });
  });
});
