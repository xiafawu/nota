# Eagle cross-recording speaker identity

**Status:** Approved (design)
**Date:** 2026-06-04
**Surface:** CLI (primary) + macOS app (lights up via existing enroll queue)
**Supersedes:** the pyannote-embedding backend assumed by
`2026-05-22-in-transcript-speaker-naming-design.md` (that spec's UI/sidecar
flow stays; only the voiceprint *backend* and *capture timing* change here).

## Overview

Make "name a speaker once → recognized automatically in every future
recording" actually work. The machinery was already wired (voiceprint store,
`--identify` matching, viewer naming → `nota enroll`), but it is structurally
unreachable in practice:

1. **No embedder** — identity used pyannote, which is not installed and which
   the user does not want to maintain (heavy torch + HF-token setup).
2. **Audio is gone before enrollment** — `sourcePath` in history points at a
   `.nota-input-*.m4a` temp staging file the share handler deletes after the
   run. The viewer's *post-hoc* enroll extracts embeddings from that path, so
   it always fails (`AUDIO-GONE`), independent of the embedder.

This redesign swaps the embedder to **Picovoice Eagle** (`@picovoice/eagle-node`,
on-device, no Python/torch/HF) and moves all voice work to **during the
pipeline run**, capturing a tiny per-speaker audio clip so naming can enroll
later without the original audio.

## Goals

- During a run, **auto-recognize** already-enrolled speakers and apply their
  names with no prompt (the mark-once payoff).
- Capture a short per-speaker PCM clip during the run so a speaker can be
  **enrolled later** (from the viewer) with the original audio already deleted.
- `nota enroll <history-id> <label> <name>` enrolls from the **stored clip**,
  not the original audio.
- Remove the pyannote dependency from the identity path entirely.
- Degrade clearly (visible message), never silently, when the AccessKey is
  missing or a speaker has too little speech to enroll.

## Non-goals

- Diarization changes. Speaker segmentation still comes from AssemblyAI
  (default) or pyannote (whisper path). Eagle does identity only.
- Real-time / streaming recognition. Batch, per recording.
- Cloud speaker-ID. Eagle is on-device; no audio leaves the machine.
- Retaining the full source audio. Only short per-speaker clips, prunable.
- Backfilling identity for the 14 existing history records (their audio and
  clips do not exist). New runs only.

## Architecture

```text
DURING pipeline run  (orchestrator, audio file still present)
  AssemblyAI ─> utterances [{ speaker: A/B/C, start, end, text }]
  ffmpeg decode input ─> 16kHz mono s16le PCM (whole file, in tmp)
  group utterances by speaker label
  Eagle init (PICOVOICE_ACCESS_KEY)              [skip identity if absent]
    load enrolled profiles  <─ ~/.nota/speakers.json
    for each speaker label:
      ├─ RECOGNIZE: feed label's frames to Eagle.process
      │     → mean score per enrolled profile
      │     → best ≥ MATCH_THRESHOLD  ⇒ auto-name (tentative band ⇒ prompt/TTY)
      └─ CAPTURE: concat label's longest utterances up to CLIP_TARGET_SEC
            write ~/.nota/history/<id>.assets/<label>.pcm   (16k mono s16le)
  history record gains:  speakerClips: { "Speaker 1": "<id>.assets/Speaker 1.pcm", ... }
  apply matched names to segments  ─> transcript / output

LATER  (macOS viewer, original audio long deleted)
  user types a name on a still-generic chip
    sidecar JSON updated (display)        [unchanged from 05-22 spec]
    EnrollQueue ─> nota enroll <id> <label> <name>      [unchanged shell-out]
      enroll loads history record
      reads STORED CLIP  ~/.nota/history/<id>.assets/<label>.pcm   ← key change
      Eagle enroll(clip) ─> profile bytes ─> append to speakers.json[name]
  next run: RECOGNIZE auto-applies that name across recordings
```

Two independent concerns, deliberately separated:
- **Capture timing** (the architectural fix): embeddings/clips captured while
  audio exists. Required by *any* voice approach.
- **Embedder** (the swap): Eagle. Replaceable without touching capture timing.

## Eagle integration (`src/pipeline/eagle.ts`, new)

Thin wrapper over `@picovoice/eagle-node`. Public surface:

- `isEagleAvailable(): boolean` — AccessKey present + module loads.
- `enrollFromPcm(pcm: Int16Array): Promise<{ profile: Buffer; percent: number }>`
  — feed frames to an `EagleProfiler` until 100%; return exported profile bytes.
  Throws `InsufficientSpeechError` if enrollment never reaches 100%.
- `recognize(pcmByLabel: Record<string, Int16Array>, profiles: EagleProfile[])`
  `: Record<string, { index: number; score: number }>` — best enrolled profile
  per label via `Eagle.process` mean score. `profiles` is a **flat** list
  (one entry per voiceprint across all names); `index` points into it and the
  caller maps index → name. Since it's a global max over every profile, the
  winning index's name is exactly the max-score name (satisfies "max across a
  name's voiceprints").

PCM contract everywhere: **16 kHz, mono, signed 16-bit little-endian**, framed
to `eagle.frameLength`. Decode with
`ffmpeg -i <in> -f s16le -ar 16000 -ac 1 -`.

## Store schema (`~/.nota/speakers.json`)

Keep the v2 pointer model (name → array of voiceprints). Change the payload:

```json
{
  "version": 3,
  "speakers": {
    "Alice": {
      "voiceprints": [
        { "id": "2026-06-04T...Z", "profile": "<base64 Eagle profile>",
          "enrolledAt": "2026-06-04T...Z", "source": "standup.m4a" }
      ]
    }
  }
}
```

- `embedding: number[]` (pyannote float vector) → `profile: string` (base64
  Eagle profile blob). `id` / `enrolledAt` / `source` unchanged.
- `version` 2 → 3. Migration: there is no live v2 data (store is empty for the
  user). On load, a v1/v2 record with `embedding` and no `profile` is **dropped
  with a one-line stderr note** (cannot convert a pyannote vector into an Eagle
  profile). `nota speakers` commands operate on `profile` going forward.
- Recognition over multiple voiceprints per name = **max** score across that
  name's profiles (drift capture: same person, several enrollments).

## Capture: per-speaker clips

- `CLIP_TARGET_SEC` (~24 s) of a speaker's *longest* utterances, concatenated,
  trimmed to target. Enough for reliable Eagle enrollment; small on disk
  (16 kHz mono s16le ≈ 32 KB/s → ~0.75 MB/speaker).
- Stored under `~/.nota/history/<id>.assets/<label>.pcm`. History record holds
  the relative pointer in a new `speakerClips: Record<label, relPath>` field.
- Speakers with < `CLIP_MIN_SEC` (~5 s) of speech: no clip, no enroll later
  (record the reason so the viewer chip shows "too little speech").
- Capture runs only when identity is active (AccessKey present). No AccessKey
  ⇒ no clips, no Eagle, generic labels — with a clear message.

## Recognition thresholds (`src/pipeline/eagle.ts`)

Mirror the existing confidence-band UX (so the prompt logic is unchanged):

- `MATCH_THRESHOLD` (~0.6 Eagle score) — auto-assign name, no prompt.
- `TENTATIVE_THRESHOLD` (~0.4) — prompt to confirm if TTY; else keep generic.
- below — unmatched.

Exact values tuned during implementation against a couple of real recordings;
defaults are starting points, exported for test override.

## `nota enroll` change (`src/cli/enroll.ts`)

Today: load record → filter segments by label → `extractEmbeddings(sourcePath)`
(pyannote) → append. **AUDIO-GONE / pyannote-missing both fatal.**

New: load record → resolve `speakerClips[label]` → read the stored PCM →
`enrollFromPcm` (Eagle) → append base64 profile. Exit codes kept (the macOS
`EnrollQueue` maps them to chip indicators):

- `2` history record not found
- `3` **stored clip missing** (was: audio missing) — chip shows amber "no clip"
- `4` Eagle unavailable (no AccessKey / module) — was: pyannote unavailable
- `5` (new) insufficient speech to enroll — distinct amber state
- `0` enrolled

## Config (`src/config.ts`)

- New `PICOVOICE_ACCESS_KEY` env var. Surfaced in `AppConfig` (e.g.
  `picovoiceAccessKey?`). Absent ⇒ identity no-ops with a one-line message
  (not a silent skip). `--identify` without a key is a clear error.
- No new CLI flag. Identity stays under the existing `--identify` /
  viewer-naming surfaces.

## Component-level changes

- `src/pipeline/eagle.ts` (new) — Eagle wrapper (enroll / recognize / avail).
- `src/utils/pcm.ts` (new) — ffmpeg decode to framed Int16 PCM; utterance-slice
  + concat-to-target helpers.
- `src/pipeline/speakers.ts` — store schema v3 (`profile` not `embedding`);
  matching delegates to `eagle.recognize`; drop pyannote `extractEmbeddings`
  from the identity path. `clusterLabels` (near-dup label merge) kept.
- `src/pipeline/history.ts` — add `speakerClips?: Record<string,string>`;
  write `<id>.assets/` clips during create.
- `src/orchestrator.ts` — `identifySpeakers` rewritten: decode PCM, recognize,
  capture clips, apply names. Same TTY-prompt branch for tentative/unmatched.
- `src/cli/enroll.ts` — enroll from stored clip (above).
- `scripts/embeddings.py` — identity-only (pyannote embedding model); no longer
  called by any path after the swap. Removed in a follow-up cleanup. (Whisper
  diarization uses its own separate pyannote script in `diarize.ts`, untouched.)
- macOS app — **no code change required** for MVP: `EnrollQueue` already shells
  `nota enroll`; its amber dots turn green once the CLI path succeeds. New exit
  code `5` → add one indicator case (small, follow-up).

## Testing plan

- `eagle.ts`: enroll a synthetic/sample clip → non-empty profile; recognize the
  same speaker scores high, a different speaker low. Gate on AccessKey in CI
  (skip with note if unset).
- `pcm.ts`: decode a fixture wav → expected length/framing; slice+concat to
  target length is deterministic.
- `speakers.ts`: v3 round-trip; max-score-across-voiceprints; v2-with-embedding
  dropped on load with note.
- `history.ts`: `speakerClips` persisted; clip written under `<id>.assets/`.
- `enroll.ts`: enroll-from-clip happy path + exit codes 2/3/4/5.
- Keep all existing tests green.

## Error surfaces (clear, never silent)

| Condition | Behavior |
|---|---|
| No `PICOVOICE_ACCESS_KEY` | identity no-ops, one-line stderr; `--identify` errors |
| Speaker < `CLIP_MIN_SEC` speech | no clip; enroll later → exit 5; chip "too little speech" |
| Stored clip missing at enroll | exit 3; chip amber "no clip" |
| Eagle module load fails | exit 4; treat as unavailable |
| Old v2 `embedding` record on load | dropped + one-line note (can't convert) |

## Open / future

- Tune thresholds + `CLIP_TARGET_SEC` on real recordings.
- Prune clips after successful enroll (or TTL); MVP keeps them.
- Whisper-path parity (diarization labels → same capture/recognize).
- macOS chip state for exit code 5.
- `nota speakers` ergonomics for Eagle profiles (no float dims to show).

## Revisions

- r1 (2026-06-04) — initial design. Eagle backend; capture-during-run + stored
  per-speaker clips; store schema v3; enroll-from-clip.
