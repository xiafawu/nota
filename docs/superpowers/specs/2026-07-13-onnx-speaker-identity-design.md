# ONNX Speaker Identity — Design Spec

**Date:** 2026-07-13
**Status:** Approved, ready for implementation
**Implementer:** external agent (Codex) — this spec is the complete handoff; assume no access to the design conversation.

## 1. Goal

Replace the Picovoice Eagle speaker-identity backend with a **pure-Node ONNX speaker-embedding** backend. No API key, no Python. Only the "PCM → speaker vector" box changes; all logic above it (diarization, per-label clip capture, name-assignment, the interactive prompt flow, the history/asset store) stays as-is.

**Motivation:** Picovoice's free tier now requires a company email, so `PICOVOICE_ACCESS_KEY` is unobtainable for this user. Eagle is the *only* wired identity backend. Pure-Node ONNX was chosen over Resemblyzer to keep the default (AssemblyAI) path Python-free — Resemblyzer would pull PyTorch (~2 GB).

## 2. Background — how identity works today

`--identify` recognizes recurring speakers by voice across recordings and prompts for unknown ones. On-device only.

Current flow (`src/orchestrator.ts` → `identifySpeakers`):
1. `decodePcm(inputPath)` → mono 16 kHz `Int16Array` (`src/utils/pcm.ts`, `SAMPLE_RATE = 16000`).
2. Per diarized label, `slicePcm` the longest voiced ranges into one clip (target seconds; `CLIP_MIN_SEC` floor). Result: `pcmByLabel: Record<string, Int16Array>`.
3. `matchProfiles(accessKey, pcmByLabel, store)` (`src/pipeline/speakers.ts`) → per-label `MatchResult`.
4. Confident matches applied; tentative-band matches + unknowns go to `promptForSpeakerNames` (interactive TTY, y/n/new).
5. Fresh names → `enrollProfile(accessKey, clip)` → store; clips also persisted under `~/.nota/history/<id>.assets/<label>.pcm` for post-hoc `nota enroll`.

**Eagle's model:** it scores *audio against an opaque profile blob* inside the SDK (`recognize()` needs raw PCM at match time). Stored voiceprint = base64 Eagle profile bytes.

**Consumers of `src/pipeline/eagle.ts`:** `orchestrator.ts`, `speakers.ts`, `cli/enroll.ts`, `config.ts` (key plumbing only).

## 3. Core change — cosine on embeddings

An ONNX speaker model produces a fixed **L2-normalized d-vector** per clip. Matching becomes **cosine similarity** on stored vectors — pure arithmetic in TypeScript. Consequence: Python-free, key-free, and `rankMatches` + the entire prompt/assignment flow are **unchanged**. Only the vector-producing box swaps.

This revives the pre-v3 embedding shape (v3 dropped `embedding: number[]` for Eagle's opaque `profile`).

## 4. Module layout

```
NEW  src/pipeline/embed.ts    ONNX d-vector backend. Replaces eagle.ts.
NEW  src/utils/model.ts       Resolve ~/.nota/models/<name>.onnx; download-if-missing + SHA-256 verify.
EDIT src/pipeline/speakers.ts Voiceprint.profile(b64) -> embedding(number[]); matchProfiles takes
                              label embeddings, cosine vs stored, feeds existing rankMatches.
EDIT src/orchestrator.ts      Compute label embeddings once/run via embed.ts; drop accessKey plumbing.
EDIT src/config.ts            Identity gated on model availability, not PICOVOICE_ACCESS_KEY.
EDIT src/cli/enroll.ts        nota enroll uses computeEmbedding; drop key gate.
DEL  src/pipeline/eagle.ts    + remove @picovoice/eagle-node from package.json.
NEW  scripts/validate-embed.ts (or tests/) Model+featurization validation harness (see §9, task 1).
```

New runtime dep: `onnxruntime-node` (prebuilt CPU binaries for macOS arm64 — no compile step).

## 5. The load-bearing unknown — model + featurization

**This is the top risk and MUST be validated before any downstream wiring (task 1).**

Speaker nets consume mel-filterbank features, not raw waveform. Two sub-cases:
- **Preferred:** an ONNX export with featurization **in-graph** → feed float PCM directly. No JS DSP.
- **Fallback:** model expects ~80-dim fbank → implement kaldi-compatible fbank in JS (25 ms window / 10 ms hop / Hamming / mel filterbank / log). A wrong constant silently wrecks accuracy, so it must be validated numerically against a reference.

**Leading candidate:** WeSpeaker ResNet34 (VoxCeleb, permissive license, 256-d). If it needs external fbank and validation is shaky, evaluate 3D-Speaker CAM++ or a model with in-graph featurization. The implementer picks the final model in task 1 and **records the choice, its SHA-256, license, download URL, output dim, and featurization mode** in this spec's §11 before proceeding.

**Thresholds are model-specific and empirically calibrated** — do NOT hardcode blindly. Initial guess: `MATCH_THRESHOLD ≈ 0.5`, `TENTATIVE_THRESHOLD ≈ 0.35` cosine; tune on a real 2-speaker sample so same-speaker pairs land above MATCH and cross-speaker below TENTATIVE.

## 6. `src/pipeline/embed.ts` — interface

```ts
export const MATCH_THRESHOLD: number;      // cosine, calibrated (see §5)
export const TENTATIVE_THRESHOLD: number;

export class InsufficientSpeechError extends Error {}  // reuse existing semantics

/** True when the model resolves (present or downloadable) and an ORT session loads. */
export function isIdentityAvailable(): Promise<boolean>;

/** Embed one clip -> L2-normalized d-vector. Throws InsufficientSpeechError if the
 *  clip has too few samples to embed. */
export function computeEmbedding(pcm: Int16Array): Promise<Float32Array>;

/** Batch: embed every label's clip in ONE loaded session (loaded once per process,
 *  cached module-level). Labels too short to embed are omitted (mirror Eagle). */
export function computeEmbeddings(
  pcmByLabel: Record<string, Int16Array>,
): Promise<Record<string, number[]>>;

/** Cosine similarity of two L2-normalized vectors. */
export function cosine(a: number[], b: number[]): number;
```

Int16 → float32 in `[-1, 1]` via `sample / 32768`. Session cached module-level (load once). Featurization per §5.

## 7. `src/utils/model.ts` — model resolver

```ts
export interface ModelSpec { name: string; url: string; sha256: string; }
/** Return local path to the .onnx, downloading to ~/.nota/models/<name> if absent.
 *  Download to a temp file, verify SHA-256, atomic-rename into place (no partial files).
 *  Throws on network failure or checksum mismatch (leaves no partial file). */
export function resolveModel(spec: ModelSpec): Promise<string>;
```

- Dir: `~/.nota/models/` (create recursively).
- Download uses Node 18+ global `fetch` (repo runs Node ≥18; dev on v20).
- SHA-256 via `node:crypto`; mismatch → delete temp, throw actionable error.
- The `ModelSpec` (url + sha256) lives as a constant in `embed.ts`.

## 8. Store schema v4 (`src/pipeline/speakers.ts`)

- `STORE_VERSION` 3 → 4.
- `Voiceprint`: replace `profile: string` with `embedding: number[]` (L2-normalized). Keep `id`, `enrolledAt`, `source`.
- `loadProfiles`: keep only v4-shaped voiceprints (those with a numeric `embedding` array). Drop v3 records carrying `profile` (same drop-and-warn path that already drops legacy records). Update the warn message: "dropped N Eagle speaker profile(s) incompatible with the ONNX backend; re-enroll to restore."
- One name → N voiceprints unchanged. Cosine takes the **max** across a name's voiceprints (extra enrollments only help recall).
- `matchProfiles` new signature: takes **label embeddings** (not raw PCM, not accessKey), computes cosine of each label vector against every stored voiceprint, builds the index-aligned score vectors, and feeds **the existing `rankMatches` unchanged**:
  ```ts
  export function matchProfiles(
    labelEmbeddings: Record<string, number[]>,
    store: SpeakerStore,
  ): Record<string, MatchResult>;
  ```
- `encodeProfile`/`decodeProfile` (base64) removed. `rankMatches`, `applySpeakerNames`, `promptForSpeakerNames` untouched.

## 9. Data flow — a `--identify` run

```
audio -> decodePcm (16kHz Int16, EXISTS)
      -> per-label clips: slicePcm longest-first to target (EXISTS)
      -> computeEmbeddings(pcmByLabel)          [NEW: one ORT session, batch]
      -> matchProfiles(labelEmbeddings, store): cosine -> rankMatches (EXISTS)
      -> tentative/confirm prompt (EXISTS, unchanged)
      -> fresh names: computeEmbedding(clip) -> store v4 (NEW vector, same save path)
```

`nota enroll` (post-hoc from a stored `.pcm`) uses the same `computeEmbedding`.

## 10. config / availability / errors

- `src/config.ts`: remove `picovoiceAccessKey`. Keep the `identify` flag. Identity availability is no longer key-gated.
- `isIdentityAvailable()` replaces `isEagleAvailable(key)` at call sites in `orchestrator.ts` and `cli/enroll.ts`.
- Absent/failed model, or ORT load failure → identity **no-ops with a clear, actionable message**; the rest of the pipeline continues (mirrors today's key-missing behavior). New message names the model download/onnxruntime, not Picovoice.
- Too little speech for a label → skip that label.
- Download SHA-256 mismatch / network fail → error surfaced; `--identify` degrades to no-op.

## 11. Model selection record (implementer fills in task 1)

- Model: WeSpeaker ResNet34-LM (`wespeaker_en_voxceleb_resnet34_LM.onnx`), trained on VoxCeleb2 Dev; ONNX deployment artifact published by sherpa-onnx
- Download URL: `https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx`
- SHA-256: `e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012` (also published in the release's `checksum.txt`)
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- Output dim: 256 (`feats` float32 `[B,T,80]` → `embs` float32 `[B,256]`)
- Featurization: JS-fbank, matching the official WeSpeaker evaluation frontend: mono 16 kHz; 80-bin Kaldi fbank; 25 ms frames; 10 ms shift; 512-point FFT; Hamming window; 20–8000 Hz; pre-emphasis 0.97; per-frame DC removal; no dither; natural-log power; utterance cepstral mean normalization (CMN), no variance normalization. `scripts/validate-embed.ts` measured maximum absolute feature error `3.075600e-4` and mean absolute error `3.105458e-6` against `torchaudio.compliance.kaldi.fbank` over 4098 frames.
- Calibrated MATCH / TENTATIVE cosine: `0.50` / `0.35`. On the local two-speaker validation clips, same-speaker cosine was `0.873221`; different-speaker cosines were `0.331195` and `0.263530` (minimum separation margin `0.542026`).

## 12. Testing

**Unit (no model, run in CI / `npm test`):**
- `cosine()` correctness.
- `rankMatches` — keep existing tests.
- Store v3→v4: a v3 `profile` record is dropped-and-warned; a v4 `embedding` record loads.
- `resolveModel`: mock `fetch` + checksum — happy path (verify + rename) and mismatch (throws, no partial file).

**Model-gated integration (skipped when model absent so offline `npm test` stays green; document how to run):**
- 2-speaker fixture wav → embed → enroll speaker A → re-run: A recognized (≥ MATCH), B rejected (< TENTATIVE).

Run the integration test locally after the model has been installed at
`~/.nota/models/wespeaker_en_voxceleb_resnet34_LM.onnx`. Provide two separate
clips of speaker A and one clip of speaker B; these paths are intentionally not
committed so private voice data never enters the repository:

```bash
NOTA_SPEAKER_TEST_ENROLL_WAV=/path/to/speaker-a-enroll.wav \
NOTA_SPEAKER_TEST_SAME_WAV=/path/to/speaker-a-second.wav \
NOTA_SPEAKER_TEST_DIFFERENT_WAV=/path/to/speaker-b.wav \
npx vitest run tests/pipeline/embed.integration.test.ts
```

**Validation harness (task 1, the risk-killer):** `scripts/validate-embed.ts` — embed two clips of the *same* speaker + one of a *different* speaker; assert same-pair cosine ≫ diff-pair. Proves model + featurization before any wiring. This gates all downstream tasks.

## 13. Cleanup

**In scope:**
- Remove the `PICOVOICE_ACCESS_KEY` line from `~/.nota/config` scaffold and from `~/.secrets` `__shell_env_load` list (both added earlier in the setup session; now dead). *(The requesting user will do the `~/.secrets` revert; note it in the PR so it isn't forgotten.)*
- Update `CLAUDE.md`: Eagle → ONNX backend, drop `PICOVOICE_ACCESS_KEY` from External Requirements + Key Design Decisions, store schema v3 → v4.
- Remove `@picovoice/eagle-node` from `package.json`.

**Out of scope (follow-up):** the macOS Swift app has a Picovoice API-key field (`macos/Nota/App/...`) — updating that UI is a separate task; this spec covers the TypeScript CLI pipeline only.

## 14. Ordered task list (for the implementation plan)

1. **Model validation harness** — pick model, fill §11, prove same-vs-diff cosine separation. Blocks everything.
2. `src/utils/model.ts` + unit tests (mock fetch/checksum).
3. `src/pipeline/embed.ts` (session cache, featurization, embedding, cosine, thresholds).
4. Store v4 in `speakers.ts` + migration + `matchProfiles` re-signature; unit tests.
5. Rewire `orchestrator.ts` + `cli/enroll.ts` + `config.ts`; delete `eagle.ts`; drop dep.
6. Model-gated integration test.
7. Cleanup + docs (§13).
