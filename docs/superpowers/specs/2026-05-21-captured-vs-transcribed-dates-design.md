# Captured vs Transcribed Dates — Design

**Date:** 2026-05-21
**Status:** Approved (brainstorming) → ready for implementation plan

## Problem

A recording captured last week and transcribed today carries two distinct
timestamps, but Nota records only one. The markdown header field `**Date:**`
is set to `new Date()` at write time, so it is silently the *processing*
(transcribed) date — there is no captured date anywhere in the output or in
history.json. Users cannot tell when audio was actually recorded.

## Goal

Surface two distinct dates everywhere Nota reports on a transcript:

- **Captured** — when the audio was recorded.
- **Transcribed** — when Nota processed the file (now).

## Decisions (locked during brainstorming)

1. **Captured-date source:** container metadata first, filesystem fallback.
   - Try ffprobe `format_tags=creation_time` (the true recording time baked
     into m4a/mp4/mov/qta containers; survives copy/AirDrop/download).
   - Fall back to `fs.stat(inputPath).birthtime` if no metadata tag.
   - If neither yields a usable date → captured is **unknown** (`null`).
2. **Display:** always show both lines. When captured is unknown, render
   `**Captured:** —`.
3. **Scope:** CLI markdown header **and** history.json. Persisting
   `capturedAt` to history lets the macOS app later show real capture date
   instead of processing time. The macOS app is not modified in this change —
   only the data is made available.

## Architecture

### New unit: `src/utils/capture-date.ts`

Single responsibility — resolve the capture time of the *original* input file.

```text
resolveCaptureDate(inputPath: string) : Promise<Date | null>
  ├─ ffprobe -show_entries format_tags=creation_time   → parse → Date
  │     (true record time)
  ├─ else fs.stat(inputPath).birthtime (valid, non-zero) → Date
  │     (disk-create time; may be "today" on copied files)
  └─ else                                               → null
        (unknown)
```

- Returns `Date | null`. `null` (unknown) is a first-class value — callers
  branch on it rather than catching exceptions.
- ffprobe is already a project dependency (`src/utils/ffmpeg.ts`
  `getAudioDuration`), so no new external requirement.
- Reads from `inputPath` (the original file) only — never the temporary
  `.qta`→`.wav` / `.m4a` conversion copies, which lose the original
  timestamp.

### Data flow (applies to BOTH pipeline paths: assemblyai + whisper)

```text
inputPath ─┬─ resolveCaptureDate ─→ capturedAt: Date | null
           │                          ├─ .toISOString()        → history.json  capturedAt
           │                          └─ .toISOString()[0..10] → write          capturedDate
           └─ new Date() ───────────→ transcribedAt
                                        ├─ (history createdAt already = this)
                                        └─ .toISOString()[0..10] → write         transcribedDate
```

Orchestrator computes `capturedAt` once per run (early, after validation),
derives the ISO string for history and the `YYYY-MM-DD` string for markdown.

### `src/pipeline/write.ts`

Replace `WriteInput.date: string` with:

```ts
capturedDate: string | null;   // "YYYY-MM-DD" or null (unknown)
transcribedDate: string;       // "YYYY-MM-DD"
```

Header output:

```text
**Captured:** 2026-05-14
**Transcribed:** 2026-05-21
**Duration:** 12 minutes
**Source:** meeting.m4a
```

When `capturedDate === null`: `**Captured:** —`.

### `src/pipeline/history.ts`

Add `capturedAt: string | null` to `HistoryRecord` and `CreateHistoryInput`.
`createdAt` already equals the transcribe/processing time, so no separate
`transcribedAt` field is needed. `createHistoryRecord` writes the new field;
older history files without it read as `undefined` (treated as unknown).

### `src/orchestrator.ts` (two call sites: ~line 191, ~line 390)

```ts
const capturedAt = await resolveCaptureDate(inputPath);   // Date | null
const transcribedAt = new Date();
const capturedDate = capturedAt ? capturedAt.toISOString().split("T")[0] : null;
const transcribedDate = transcribedAt.toISOString().split("T")[0];
```

Pass `capturedAt?.toISOString() ?? null` into `createHistoryRecord`, and
`{ capturedDate, transcribedDate, ... }` into `writeOutput`.

## Known limitations (accepted, not blocking)

- **UTC dates.** `.toISOString()` yields a UTC calendar date. A late-night
  local recording can show the next UTC day. This already holds for the
  existing transcribed date; we stay consistent rather than introduce a
  timezone divergence between the two fields.
- **birthtime portability.** On some filesystems `birthtime` is unavailable
  or zero/epoch; that case is treated as unknown (falls through to `null`).
- **Stream-level vs format-level tags.** Some files carry `creation_time`
  only at stream level. v1 reads `format_tags` only; stream-tag fallback can
  be added later if a real file needs it.

## Testing

- `resolveCaptureDate`:
  - metadata hit → returns parsed container date.
  - no metadata, valid birthtime → returns birthtime date.
  - neither available → returns `null`.
- `buildMarkdown`:
  - both dates present → header has `**Captured:**` and `**Transcribed:**`.
  - `capturedDate === null` → header shows `**Captured:** —`.
- `history`: `createHistoryRecord` persists `capturedAt`; round-trips on read.

## Out of scope

- macOS app UI changes (data made available via `capturedAt`, consumed later).
- Backfilling `capturedAt` into pre-existing history records.
- Per-segment / timezone-localized rendering.
