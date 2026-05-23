# In-transcript speaker naming

**Status:** Approved
**Date:** 2026-05-22
**Surface:** macOS app only

## Overview

Let users name `Speaker 1`, `Speaker 2`, … in the rendered transcript view
of the macOS app. Names persist in a sidecar JSON next to the .md
(`<doc>.summary.md` + `<doc>.summary.speakers.json`). The body of the .md
is **never rewritten** — substitution happens at render time, so renames
are reversible by deleting the sidecar.

Every rename also auto-enrolls a voiceprint into `~/.nota/speakers.json`
under the chosen name so future `nota --identify` runs auto-recognize the
same speaker across recordings. This closes the loop between this morning's
pointer-model speaker store and the manual labeling UI.

## Goals

- Click `Speaker N` chip in the document header → type a name → renamed
  everywhere in the rendered transcript, immediately.
- Sidecar JSON keeps body untouched. Reversible.
- Auto-enroll voiceprint when a history record + audio are available.
- Survive missing audio / pyannote / Python: degrade to display-only
  rename with a visible hint, never block the UI.

## Non-goals

- Editing other transcript text (just speaker labels).
- A CLI subcommand for manual naming (we already have
  `nota speakers reassign` for voiceprint-level fixes).
- Retroactive substitution in existing .md files without sidecars —
  user must explicitly rename.

## Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│ DocumentHeaderView                                          │
│   title · subtitle · tags                                   │
│   [Speaker 1: ?] [Speaker 2: Alice ✓] [Speaker 3: ⏳]       │ ← chip strip
└────────┬────────────────────────────────────────────────────┘
         │ click chip → text field → Enter
         ▼
┌────────────────────┐    ┌──────────────────────────┐
│ SpeakerSidecar     │───▶│ <doc>.summary.speakers.   │  (immediate)
│  read / write      │    │  json                     │
└────────┬───────────┘    └──────────────────────────┘
         │
         │ also enqueue async job
         ▼
┌────────────────────┐    ┌──────────────────────────┐
│ EnrollQueue        │───▶│ shell: nota enroll        │
│  (serial, Swift)   │    │   <history-id> <label>    │
└────────┬───────────┘    │   <name>                  │
         │                └──────────┬───────────────┘
         │                           │ pyannote (embeddings.py)
         │                           ▼
         │                ┌──────────────────────────┐
         │                │ ~/.nota/speakers.json    │
         │                │  (v2 pointer model:      │
         │                │   append voiceprint)     │
         │                └──────────────────────────┘
         ▼
┌────────────────────┐
│ MarkdownRender     │
│  substitute names  │
│  at render time    │
└────────────────────┘
```

## Sidecar JSON schema

File: `<doc>.summary.speakers.json` (sibling of the .md).

```json
{
  "version": 1,
  "speakers": {
    "Speaker 1": "Alice",
    "Speaker 2": "Bob"
  }
}
```

- Key = original label as parsed from body (`**Speaker N:**`).
- Value = display name. Empty string or missing key → no override.
- `version` lets us evolve the schema later (e.g. add enrollment status
  per label) without breaking older files.

## Speaker label discovery

Parse the rendered .md body for lines matching the pattern emitted by
[src/pipeline/write.ts](../../src/pipeline/write.ts):

```
[MM:SS] **Speaker N:** text
```

Regex (same one `MarkdownRender.appendTranscriptLine` already uses):
`^\[([0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)\] \*\*(.+?):\*\* (.*)$`. Capture
group 2 is the label. Unique labels (preserving first-seen order) drive
the chip strip.

This works for any .md from this pipeline regardless of whether a history
record exists. Sidecar override happens after discovery; chip strip shows
discovered labels with current sidecar name (or `?` when unmapped).

## History-record lookup for audio

To enroll a voiceprint we need (a) the source audio file and (b) the
segments belonging to the label being renamed. Both live in the history
record at `~/.nota/history/<id>.json`.

Lookup: walk `~/.nota/history/*.json` once on doc-open and find the record
whose `outputPath` matches the current .md absolute path. Cache the
`HistoryRecord` (or `nil`) on the document model. When the chip strip
fires a rename:

- record found + audio file exists → enroll (full path)
- record found + audio file missing → enrollment fails gracefully
- no record found (imported .md) → enrollment skipped silently

The chip indicator reflects which state we're in.

## Component-level changes

| File | Status | Purpose |
|---|---|---|
| `macos/Nota/UI/DocumentHeaderView.swift` | edit | inject chip strip below subtitle |
| `macos/Nota/UI/SpeakerChipsView.swift` | new | chip + popover + rename text field |
| `macos/Nota/UI/MarkdownRender.swift` | edit | apply override map during attributed-string build |
| `macos/Nota/App/SpeakerSidecar.swift` | new | sidecar load/save with atomic write |
| `macos/Nota/App/SpeakerProfileStore.swift` | edit | v1→v2 Codable migration (blocker fix) |
| `macos/Nota/App/NotaModel.swift` | edit | wire enroll queue; cache history-record-for-doc |
| `macos/Nota/App/EnrollQueue.swift` | new | serial Swift `TaskQueue` for `nota enroll` shells |
| `src/cli/enroll.ts` | new | `nota enroll <history-id> <label> <name>` |
| `src/index.ts` | edit | register `enroll` subcommand |
| `tests/cli/enroll.test.ts` | new | round-trip enrollment against fixture history |

## `nota enroll` subcommand (CLI)

Signature: `nota enroll <history-id> <speaker-label> <name>`

Steps:
1. `loadHistoryRecord(idOrPrefix)` from `~/.nota/history/`.
2. Filter `record.segments` to those with `speaker === <label>`.
3. Verify `record.sourcePath` exists; error with stable exit code if not.
4. `extractEmbeddings(record.sourcePath, filteredSegments)` returns a single
   embedding under the original label key.
5. `loadProfiles()` (v2 shape after this morning's deploy).
6. Append `{ id: now, embedding, enrolledAt: now, source: basename(sourcePath) }`
   to `profiles.speakers[<name>].voiceprints` (creating the profile if
   missing). Same code path as orchestrator's enroll block — extract into
   a shared helper.
7. `saveProfiles()`.

Exit codes for the caller (Swift) to switch on:
- `0` → success
- `2` → history record not found
- `3` → audio file missing
- `4` → pyannote / Python unavailable
- `1` → any other failure (stderr carries detail)

## Render-time substitution

`MarkdownRender.swift` already produces an `NSAttributedString` from
markdown. Add an `overrides: [String: String]` parameter to the entry
point and, while scanning lines, when a `**<label>:**` run is detected,
substitute `<label>` with `overrides[<label>] ?? <label>` before
attribution. Original timestamp prefix logic unchanged.

The body string passed to `RichTextViewer` is regenerated whenever the
sidecar changes; SwiftUI re-renders without disk mutation.

## Chip strip UI

`SpeakerChipsView`:
- Rounded-rect chip per label, ordered by first-seen in body.
- Idle state: `Speaker 1 → ?` (muted).
- Mapped state: `Speaker 1 → Alice` (text + small indicator dot).
- Indicator dot color: green ✓ enrolled, amber ⚠ no audio / no record,
  spinning ⏳ enrolling, red ✗ enroll error (tooltip = stderr tail).
- Click → inline `TextField` replaces chip body; Enter commits, Esc
  cancels. Empty string commit = clear mapping (delete sidecar entry).

Apple HIG / Tahoe styling per
[`apple-tahoe-spacing-grid`](~/.claude/skills/apple-tahoe-spacing-grid)
and [`apple-glass-secondary-text-contrast`](~/.claude/skills/apple-glass-secondary-text-contrast).

## Concurrency

`EnrollQueue` is a single-flight Swift actor / `TaskQueue` that serializes
shell invocations of `nota enroll`. Why: two rapid renames could both
load `speakers.json`, append, and race the save — last writer wins,
dropping one voiceprint. Serializing in Swift is cheaper than file-locking
in TS and matches the pattern used by `shellMergeSpeakers` in
[SpeakerProfileStore.swift](../../macos/Nota/App/SpeakerProfileStore.swift).

## Schema migration (blocker)

`SpeakerProfileStore.swift` Codable is still v1 (`embedding: [Double]` at
the top of `SpeakerProfile`). After this morning's TS deploy any new
profile written by `nota --identify` or `nota enroll` is v2
(`voiceprints: [Voiceprint]`). The current Swift code will silently fail
to decode and return `.empty` from `load()`, breaking the Settings pane.

Fix: bump Swift schema to mirror TypeScript:

```swift
struct Voiceprint: Codable, Hashable {
  var id: String
  var embedding: [Double]
  var enrolledAt: String
  var source: String
}
struct SpeakerProfile: Codable, Hashable {
  var voiceprints: [Voiceprint]
}
```

Add `init(from decoder:)` on `SpeakerProfile` that tries v2 first then
falls back to wrapping a v1 single-embedding into a one-element
`voiceprints` array. Mirror the `migrateProfile` logic from
[src/pipeline/speakers.ts](../../src/pipeline/speakers.ts).

Update `SpeakersSettings.swift` to display voiceprint count + first
voiceprint's `enrolledAt`/`source` (or list them). Out of scope for this
spec to add a per-voiceprint UI — leave a TODO.

## Testing plan

- **TS:** `tests/cli/enroll.test.ts` covers happy path (fixture history +
  fixture audio + fixture pyannote stub via `PYTHON_BIN` override),
  missing history id, missing audio, unknown speaker label.
- **Swift:** unit-test sidecar round-trip (`SpeakerSidecar.load` /
  `.save`), label parsing on a fixture markdown, schema migration
  decoder for v1 → v2 input.
- **Manual smoke:** deploy app, open a transcript with multiple speakers,
  rename Speaker 1, confirm body re-renders, sidecar appears, voiceprint
  shows up in `nota speakers list`.

## Error surfaces

| Condition | Sidecar | Voiceprint | UI signal |
|---|---|---|---|
| Happy path | written | enrolled | chip turns green ✓ |
| No history record | written | skipped | amber ⚠ + tooltip "no history record" |
| History present, audio gone | written | skipped | amber ⚠ + tooltip "audio missing" |
| Python / pyannote missing | written | skipped | amber ⚠ + tooltip "voiceprint runtime unavailable" |
| Embedding extraction crashed | written | skipped | red ✗ + tooltip with stderr tail |

Sidecar is always written if the user provided a name. The chip never
gets stuck in an in-progress state because the queue task always settles
in finite time (timeout = 30s on the shell).

## Open / future

- Phase 2: surface "Suggested matches" in the chip popover when the
  voiceprint partially matches an existing profile (tentative band) —
  reuse the `matchSpeakers` confidence band from speakers.ts.
- Phase 2: a "speakers" inspector pane with full history per speaker,
  not just per-document. Out of scope for V1.
- Phase 3: drag a chip from the strip onto a transcript line to assign
  even when the diarizer over-segmented (rare).

## Revisions

(none yet)
