#!/usr/bin/env node

import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

import * as ort from "onnxruntime-node";

import {
  cosine,
  kaldiFbank,
  MATCH_THRESHOLD,
  MODEL_SPEC,
  TENTATIVE_THRESHOLD,
  type FbankMatrix,
} from "../src/pipeline/embed.js";
import { decodePcm } from "../src/utils/pcm.js";

export const MIN_SEPARATION_MARGIN = 0.1;

function runReferenceFbank(pcm: Int16Array, python: string): Promise<FbankMatrix> {
  const source = String.raw`
import struct, sys
import numpy as np
import torch
from torchaudio.compliance import kaldi

pcm = np.frombuffer(sys.stdin.buffer.read(), dtype='<i2').astype(np.float32)
waveform = torch.from_numpy(pcm).unsqueeze(0)
feat = kaldi.fbank(
    waveform,
    num_mel_bins=80,
    frame_length=25,
    frame_shift=10,
    dither=0.0,
    sample_frequency=16000,
    window_type='hamming',
    use_energy=False,
)
feat = feat - torch.mean(feat, dim=0)
array = feat.contiguous().numpy().astype('<f4', copy=False)
sys.stdout.buffer.write(struct.pack('<II', array.shape[0], array.shape[1]))
sys.stdout.buffer.write(array.tobytes())
`;

  return new Promise((resolve, reject) => {
    const child = spawn(python, ["-c", source], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(
          new Error(
            `${python} torchaudio reference failed (${code}): ${Buffer.concat(stderr).toString("utf8")}`,
          ),
        );
        return;
      }
      const output = Buffer.concat(stdout);
      if (output.length < 8) {
        reject(new Error("torchaudio reference returned an invalid payload"));
        return;
      }
      const frames = output.readUInt32LE(0);
      const bins = output.readUInt32LE(4);
      const bytes = output.subarray(8);
      if (bytes.length !== frames * bins * 4) {
        reject(new Error("torchaudio reference returned an invalid feature shape"));
        return;
      }
      const data = new Float32Array(frames * bins);
      for (let i = 0; i < data.length; i++) data[i] = bytes.readFloatLE(i * 4);
      resolve({ data, frames, bins });
    });

    const input = Buffer.allocUnsafe(pcm.length * 2);
    for (let i = 0; i < pcm.length; i++) input.writeInt16LE(pcm[i], i * 2);
    child.stdin.end(input);
  });
}

function normalize(values: Float32Array): Float32Array {
  let squared = 0;
  for (const value of values) squared += value * value;
  const norm = Math.sqrt(squared);
  if (!Number.isFinite(norm) || norm === 0) throw new Error("model produced a zero/invalid embedding");
  return Float32Array.from(values, (value) => value / norm);
}

export function assertCosineValidation(
  sameScore: number,
  differentA: number,
  differentB: number,
): void {
  if (sameScore < MATCH_THRESHOLD) {
    throw new Error(
      `same-speaker cosine does not meet MATCH threshold ${MATCH_THRESHOLD.toFixed(2)}`,
    );
  }
  const worstDifferent = Math.max(differentA, differentB);
  if (worstDifferent >= TENTATIVE_THRESHOLD) {
    throw new Error(
      `different-speaker cosine is not below TENTATIVE threshold ${TENTATIVE_THRESHOLD.toFixed(2)}`,
    );
  }
  const margin = sameScore - worstDifferent;
  if (margin < MIN_SEPARATION_MARGIN) {
    throw new Error(
      `same-speaker cosine is not separated from different-speaker cosine by ${MIN_SEPARATION_MARGIN}`,
    );
  }
}

async function embed(
  session: ort.InferenceSession,
  path: string,
): Promise<{ embedding: Float32Array; pcm: Int16Array; fbank: FbankMatrix }> {
  const pcm = await decodePcm(path);
  const fbank = kaldiFbank(pcm);
  if (fbank.frames === 0) throw new Error(`${path}: too short for one fbank frame`);
  const result = await session.run({
    feats: new ort.Tensor("float32", fbank.data, [1, fbank.frames, fbank.bins]),
  });
  const output = result.embs;
  if (!(output?.data instanceof Float32Array) || output.data.length !== 256) {
    throw new Error(`${path}: expected model output [1,256]`);
  }
  return { embedding: normalize(output.data), pcm, fbank };
}

interface Args {
  model: string;
  sameA: string;
  sameB: string;
  different: string;
  referencePython: string;
}

export function parseArgs(argv: string[]): Args {
  const values = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key?.startsWith("--") || value === undefined) throw new Error("invalid arguments");
    values.set(key, value);
  }
  const model = values.get("--model");
  const sameA = values.get("--same-a");
  const sameB = values.get("--same-b");
  const different = values.get("--different");
  const referencePython = values.get("--reference-python");
  if (!model || !sameA || !sameB || !different || !referencePython) {
    throw new Error(
      "usage: npx tsx scripts/validate-embed.ts --model MODEL.onnx --same-a A.wav --same-b A2.wav --different B.wav --reference-python python3.11",
    );
  }
  return {
    model,
    sameA,
    sameB,
    different,
    referencePython,
  };
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const hash = createHash("sha256").update(await readFile(args.model)).digest("hex");
  if (hash !== MODEL_SPEC.sha256) {
    throw new Error(`model SHA-256 mismatch: expected ${MODEL_SPEC.sha256}, got ${hash}`);
  }

  const session = await ort.InferenceSession.create(args.model);
  const [sameA, sameB, different] = await Promise.all([
    embed(session, args.sameA),
    embed(session, args.sameB),
    embed(session, args.different),
  ]);

  console.log(`model_sha256=${hash}`);
  console.log(`model_io=feats[1,T,80] -> embs[1,256]`);

  const reference = await runReferenceFbank(sameA.pcm, args.referencePython);
  if (reference.frames !== sameA.fbank.frames || reference.bins !== sameA.fbank.bins) {
    throw new Error(
      `fbank shape mismatch: JS ${sameA.fbank.frames}x${sameA.fbank.bins}, reference ${reference.frames}x${reference.bins}`,
    );
  }
  let maxAbsolute = 0;
  let sumAbsolute = 0;
  for (let i = 0; i < reference.data.length; i++) {
    const absolute = Math.abs(reference.data[i] - sameA.fbank.data[i]);
    maxAbsolute = Math.max(maxAbsolute, absolute);
    sumAbsolute += absolute;
  }
  const meanAbsolute = sumAbsolute / reference.data.length;
  console.log(
    `fbank_reference=torchaudio frames=${reference.frames} bins=${reference.bins} max_abs=${maxAbsolute.toExponential(6)} mean_abs=${meanAbsolute.toExponential(6)}`,
  );
  if (maxAbsolute > 2e-3 || meanAbsolute > 2e-4) {
    throw new Error("JS fbank does not match the torchaudio Kaldi reference closely enough");
  }

  const sameScore = cosine(Array.from(sameA.embedding), Array.from(sameB.embedding));
  const differentA = cosine(
    Array.from(sameA.embedding),
    Array.from(different.embedding),
  );
  const differentB = cosine(
    Array.from(sameB.embedding),
    Array.from(different.embedding),
  );
  const worstDifferent = Math.max(differentA, differentB);
  const margin = sameScore - worstDifferent;
  console.log(`same_cosine=${sameScore.toFixed(6)}`);
  console.log(`different_cosine_same_a=${differentA.toFixed(6)}`);
  console.log(`different_cosine_same_b=${differentB.toFixed(6)}`);
  console.log(`separation_margin=${margin.toFixed(6)}`);
  assertCosineValidation(sameScore, differentA, differentB);
  console.log("validation=PASS");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error: unknown) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
}
