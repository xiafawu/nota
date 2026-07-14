import { SAMPLE_RATE } from "../utils/pcm.js";
import { resolveModel, type ModelSpec } from "../utils/model.js";

export const MATCH_THRESHOLD = 0.5;
export const TENTATIVE_THRESHOLD = 0.35;

export const MODEL_SPEC: ModelSpec = {
  name: "wespeaker_en_voxceleb_resnet34_LM.onnx",
  url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx",
  sha256: "e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012",
};

export const FBANK_FRAME_LENGTH = 400;
export const FBANK_FRAME_SHIFT = 160;
export const FBANK_FFT_SIZE = 512;
export const FBANK_BINS = 80;

const FLOAT32_EPSILON = 1.1920928955078125e-7;
// Kaldi's floor is defined for Int16-scale power. We convert samples to
// [-1, 1], so scale the power floor too; utterance CMN then preserves the
// numerically validated features rather than clipping quiet bins differently.
const POWER_FLOOR = FLOAT32_EPSILON / (32768 * 32768);
const EMBEDDING_DIMENSION = 256;

type OrtModule = typeof import("onnxruntime-node");
type OrtSession = Awaited<ReturnType<OrtModule["InferenceSession"]["create"]>>;

interface IdentityBackend {
  ort: OrtModule;
  session: OrtSession;
}

let backendPromise: Promise<IdentityBackend> | undefined;

function loadBackend(): Promise<IdentityBackend> {
  if (!backendPromise) {
    backendPromise = Promise.all([
      import("onnxruntime-node"),
      resolveModel(MODEL_SPEC),
    ])
      .then(async ([ort, modelPath]) => ({
        ort,
        session: await ort.InferenceSession.create(modelPath),
      }))
      .catch((error: unknown) => {
        backendPromise = undefined;
        throw error;
      });
  }
  return backendPromise;
}

export interface FbankMatrix {
  data: Float32Array;
  frames: number;
  bins: number;
}

export class InsufficientSpeechError extends Error {
  constructor() {
    super("Not enough speech to compute a speaker embedding");
    this.name = "InsufficientSpeechError";
  }
}

function melScale(frequency: number): number {
  return 1127 * Math.log(1 + frequency / 700);
}

function makeMelBanks(): Float64Array[] {
  const fftBins = FBANK_FFT_SIZE / 2;
  const lowMel = melScale(20);
  const highMel = melScale(SAMPLE_RATE / 2);
  const delta = (highMel - lowMel) / (FBANK_BINS + 1);
  const binWidth = SAMPLE_RATE / FBANK_FFT_SIZE;

  return Array.from({ length: FBANK_BINS }, (_, bin) => {
    const left = lowMel + bin * delta;
    const center = left + delta;
    const right = center + delta;
    const weights = new Float64Array(fftBins);
    for (let fftBin = 0; fftBin < fftBins; fftBin++) {
      const mel = melScale(binWidth * fftBin);
      const up = (mel - left) / (center - left);
      const down = (right - mel) / (right - center);
      weights[fftBin] = Math.max(0, Math.min(up, down));
    }
    return weights;
  });
}

const MEL_BANKS = makeMelBanks();
const HAMMING = Float64Array.from(
  { length: FBANK_FRAME_LENGTH },
  (_, i) =>
    0.54 -
    0.46 * Math.cos((2 * Math.PI * i) / (FBANK_FRAME_LENGTH - 1)),
);

/** In-place radix-2 complex FFT. */
function fft(real: Float64Array, imag: Float64Array): void {
  const n = real.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [real[i], real[j]] = [real[j], real[i]];
      [imag[i], imag[j]] = [imag[j], imag[i]];
    }
  }

  for (let length = 2; length <= n; length <<= 1) {
    const angle = (-2 * Math.PI) / length;
    const stepReal = Math.cos(angle);
    const stepImag = Math.sin(angle);
    for (let start = 0; start < n; start += length) {
      let twiddleReal = 1;
      let twiddleImag = 0;
      for (let offset = 0; offset < length / 2; offset++) {
        const even = start + offset;
        const odd = even + length / 2;
        const oddReal = real[odd] * twiddleReal - imag[odd] * twiddleImag;
        const oddImag = real[odd] * twiddleImag + imag[odd] * twiddleReal;
        real[odd] = real[even] - oddReal;
        imag[odd] = imag[even] - oddImag;
        real[even] += oddReal;
        imag[even] += oddImag;
        const nextReal = twiddleReal * stepReal - twiddleImag * stepImag;
        twiddleImag = twiddleReal * stepImag + twiddleImag * stepReal;
        twiddleReal = nextReal;
      }
    }
  }
}

/**
 * Validated WeSpeaker evaluation frontend: 16 kHz, 25 ms / 10 ms, 80-bin
 * Kaldi fbank, Hamming, no dither, and utterance cepstral mean normalization.
 */
export function kaldiFbank(pcm: Int16Array): FbankMatrix {
  if (pcm.length < FBANK_FRAME_LENGTH) {
    return { data: new Float32Array(), frames: 0, bins: FBANK_BINS };
  }

  const frames =
    1 + Math.floor((pcm.length - FBANK_FRAME_LENGTH) / FBANK_FRAME_SHIFT);
  const unnormalized = new Float64Array(frames * FBANK_BINS);
  const means = new Float64Array(FBANK_BINS);
  const real = new Float64Array(FBANK_FFT_SIZE);
  const imag = new Float64Array(FBANK_FFT_SIZE);
  const powers = new Float64Array(FBANK_FFT_SIZE / 2);

  for (let frame = 0; frame < frames; frame++) {
    const start = frame * FBANK_FRAME_SHIFT;
    let dc = 0;
    for (let i = 0; i < FBANK_FRAME_LENGTH; i++) {
      dc += pcm[start + i] / 32768;
    }
    dc /= FBANK_FRAME_LENGTH;

    real.fill(0);
    imag.fill(0);
    let previous = pcm[start] / 32768 - dc;
    for (let i = 0; i < FBANK_FRAME_LENGTH; i++) {
      const sample = pcm[start + i] / 32768 - dc;
      const emphasized = sample - 0.97 * (i === 0 ? sample : previous);
      real[i] = emphasized * HAMMING[i];
      previous = sample;
    }

    fft(real, imag);
    for (let i = 0; i < powers.length; i++) {
      powers[i] = real[i] * real[i] + imag[i] * imag[i];
    }

    for (let bin = 0; bin < FBANK_BINS; bin++) {
      let energy = 0;
      const weights = MEL_BANKS[bin];
      for (let i = 0; i < powers.length; i++) energy += powers[i] * weights[i];
      const value = Math.log(Math.max(energy, POWER_FLOOR));
      unnormalized[frame * FBANK_BINS + bin] = value;
      means[bin] += value;
    }
  }

  for (let bin = 0; bin < FBANK_BINS; bin++) means[bin] /= frames;
  const data = new Float32Array(unnormalized.length);
  for (let frame = 0; frame < frames; frame++) {
    for (let bin = 0; bin < FBANK_BINS; bin++) {
      data[frame * FBANK_BINS + bin] =
        unnormalized[frame * FBANK_BINS + bin] - means[bin];
    }
  }
  return { data, frames, bins: FBANK_BINS };
}

export async function computeEmbedding(
  pcm: Int16Array,
): Promise<Float32Array> {
  const fbank = kaldiFbank(pcm);
  if (fbank.frames === 0) throw new InsufficientSpeechError();

  const { ort, session } = await loadBackend();
  const result = await session.run({
    feats: new ort.Tensor("float32", fbank.data, [1, fbank.frames, fbank.bins]),
  });
  const output = result.embs;
  if (
    !output ||
    !(output.data instanceof Float32Array) ||
    output.data.length !== EMBEDDING_DIMENSION ||
    output.dims.length !== 2 ||
    output.dims[0] !== 1 ||
    output.dims[1] !== EMBEDDING_DIMENSION
  ) {
    throw new Error("speaker model produced an invalid embedding; expected embs[1,256]");
  }

  let squaredNorm = 0;
  for (const value of output.data) squaredNorm += value * value;
  const norm = Math.sqrt(squaredNorm);
  if (!Number.isFinite(norm) || norm === 0) {
    throw new Error("speaker model produced a zero or non-finite embedding");
  }
  return Float32Array.from(output.data, (value) => value / norm);
}

export async function computeEmbeddings(
  pcmByLabel: Record<string, Int16Array>,
): Promise<Record<string, number[]>> {
  const embeddings: Record<string, number[]> = {};
  for (const [label, pcm] of Object.entries(pcmByLabel)) {
    try {
      embeddings[label] = Array.from(await computeEmbedding(pcm));
    } catch (error) {
      if (error instanceof InsufficientSpeechError) continue;
      throw error;
    }
  }
  return embeddings;
}

export async function isIdentityAvailable(): Promise<boolean> {
  try {
    await loadBackend();
    return true;
  } catch {
    return false;
  }
}

export function cosine(a: number[], b: number[]): number {
  if (a.length !== b.length || a.length === 0) {
    throw new Error("invalid embedding dimensions");
  }

  let dot = 0;
  let normA = 0;
  let normB = 0;
  for (let i = 0; i < a.length; i++) {
    if (!Number.isFinite(a[i]) || !Number.isFinite(b[i])) {
      throw new Error("embedding values must be finite");
    }
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  if (!Number.isFinite(dot) || !Number.isFinite(normA) || !Number.isFinite(normB)) {
    throw new Error("cosine requires finite embedding norms");
  }
  if (normA === 0 || normB === 0) {
    throw new Error("cannot compare a zero-length embedding");
  }
  return dot / Math.sqrt(normA * normB);
}
