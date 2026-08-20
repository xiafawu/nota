# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Nota is a TypeScript CLI tool that transcribes and diarizes audio files using AssemblyAI (default) or OpenAI Whisper, then summarizes with an OpenAI or Gemini model (default `gpt-5-mini`). It outputs structured markdown with narrative summary, key topics, decisions, and action items.

Transcription and summary models are chosen from a curated **model registry** (`src/registry.ts`, the single source of truth). Each model id maps to a task, a provider, and the API key it requires — the provider is always derived from the model id, never stored or chosen directly.

## Naming

- Canonical product name: **Nota**
- Canonical CLI command: `nota`
- Canonical share handler: `scripts/nota-share.sh`
- Default share output folder: `~/Documents/Nota`
- Persistent speaker profiles: `~/.nota/speakers.json`
- Legacy `meetingsum` names are compatibility aliases only. Keep `scripts/meetingsum-share.sh`, the `meetingsum` bin alias, `MEETINGSUM_*` env fallbacks, and `~/.meetingsum/speakers.json` fallback unless intentionally doing a breaking cleanup.
- The repository path is `/Users/xiafawu/Developer/Nota`. Treat that as a filesystem location, not the product name.
- `docs/superpowers/` contains historical implementation plans/specs from the old name. Do not use those files as the source of truth for current branding.

## Build & Run Commands

- `npm run dev -- <audio-file>` — run Nota in development mode via tsx
- `npm start -- <audio-file>` — run compiled Nota after `npm run build`
- `npm run build` — compile TypeScript to `dist/`
- `npm test` — run all tests (vitest)
- `npm run test:watch` — run tests in watch mode
- `npx vitest run tests/pipeline/validate.test.ts` — run a single test file

## Architecture

Two pipeline paths controlled by `--provider`:

**AssemblyAI (default):** `Audio → Validate → Transcribe+Diarize (AssemblyAI) → Summarize (registry model) → Write`

**Whisper (fallback):** `Audio → Validate → Chunk → Transcribe (Whisper) + Diarize (pyannote) → Merge → Align → Summarize (registry model) → Write`

- **src/index.ts** — CLI entry point (commander). Parses args, calls orchestrator; hosts `nota settings`, `nota config`, and `nota models` verbs; runs background catalog freshness check on startup.
- **src/config.ts** — Resolves transcription + summary models (CLI > settings.json > key-aware default chain) via the registry, requires only the needed API keys, and derives the pipeline branch.
- **src/registry.ts** — Model registry: transcription models are statically curated; summary models are sourced dynamically from the catalog (`src/catalog.ts`).
- **src/catalog.ts** — Self-updating model catalog: fetches models.dev/api.json, filters through allowlist predicates, validates, and atomically caches to `~/.nota/models-catalog.json`. Baked snapshot fallback. Provides cost computation helpers. Merges the code-resident curated entries (`src/openrouter.ts`, `src/cli-engines.ts`) at read time.
- **src/cli-engines.ts** — The curated `claude-code/*` and `codex/*` entries: binary names, login hints, the "included w/ subscription" cost note. See CLI Engines below.
- **src/cli/settings.ts** — `nota settings list|get|set|unset` verbs.
- **src/constants.ts** — Shared constants: `SEGMENT_DURATION`, `OVERLAP_DURATION`, `CHUNK_THRESHOLD_BYTES`.
- **src/orchestrator.ts** — Branches on `provider` to run AssemblyAI or Whisper pipeline.
- **src/pipeline/** — One module per pipeline stage:
  - `assemblyai.ts` — single API call for transcription + diarization, handles .qta conversion
  - `validate.ts` — checks file exists, format supported, ffmpeg installed
  - `chunk.ts` — splits audio >20MB into ~10min segments with 30s overlap (whisper only)
  - `transcribe.ts` — parallel Whisper API calls, exports `TranscriptSegment` interface (shared)
  - `merge.ts` — concatenates transcripts, deduplicates overlap regions (whisper only)
  - `summarize.ts` — sends transcript to the resolved summary model (OpenAI or Gemini via the OpenAI-compatible endpoint); for >100k tokens, does section-by-section then roll-up. Branches to the subprocess caller when the resolved entry's execution kind is `cli`
  - `cli-engine.ts` — spawns `claude -p` / `codex exec` for a `cli` summary model: argv, stdin, env hygiene, timeout, failure contract, `--version` probe
  - `diarize.ts` — calls Python pyannote script, aligns speaker labels (whisper only)
  - `embed.ts` — computes ONNX WeSpeaker d-vectors in Node and compares them by cosine similarity
  - `speakers.ts` — loads the persistent v4 voiceprint store, matches diarized labels to enrolled speakers, computes tentative-band suggestions, and enforces enrollment consistency (`lowAgreement`)
  - `write.ts` — generates markdown output file; header carries **Captured** (recording time from container metadata, fs-birthtime fallback) and **Transcribed** (processing time) dates
- **src/utils/** — Shared helpers: ffmpeg wrapper (`ffmpeg.ts`), PCM decoding/slicing (`pcm.ts`), ONNX model download/cache (`model.ts`), token estimation (`tokens.ts`), capture-date resolution (`capture-date.ts`).

## CLI Flags

- `--provider <name>` — back-compat alias that seeds the transcription model: `assemblyai` (default → `universal`) or `whisper` (→ `whisper-1`). Yields to an explicit `--transcribe-model` or a `transcription.model` setting.
- `--transcribe-model <id>` — transcription model id from the registry (overrides settings.json and `--provider`)
- `--num-speakers <n>` — expected speaker count (assemblyai only)
- `--no-diarize` — skip pyannote diarization for whisper-path transcription
- `--identify` — force speaker identification on (default is auto: recognition runs on every diarized transcription whenever the store has ≥1 enrolled voiceprint)
- `--no-identify` — disable speaker identification even when voiceprints exist
- `-o, --output <path>` — output file path
- `-l, --language <lang>` — audio language hint
- `-m, --model <model>` — summary model id. Precedence: this flag > `settings.json` > key-aware default chain (`deepseek-v4-flash` > `gpt-5.4-mini` > `gemini-3.6-flash` based on available API keys).
- `--no-history` — do not save this transcript to `~/.nota/history` (also disables duplicate detection, which relies on the history store)
- `--force` — reprocess even if an identical audio file is already in history (overrides duplicate detection)

- `-v, --verbose` — show progress spinners

Duplicate detection is automatic whenever history is enabled (the default): an
identical file (same bytes) that was already transcribed reuses the prior
summary instead of re-running paid transcription. See Key Design Decisions.

### Model Management

- `nota models list` — print the effective summary catalog as tab-separated rows (id, provider, label, source, fetchedAt)
- `nota models refresh` — force a fetch from models.dev, showing added/removed ids vs the previous cache

## Speaker Management

Manage enrolled speaker voiceprints (`~/.nota/speakers.json`, with legacy
fallback to `~/.meetingsum/speakers.json`):

- `nota speakers list` — print one tab-separated row per voiceprint (name, voiceprint id, enrolledAt, source, embedding dimension) on stdout
- `nota speakers show <name>` — print profile JSON with each voiceprint's metadata and embedding dimension (not the full vector)
- `nota speakers rename <old> <new>` — rename a profile key
- `nota speakers delete <name>` — remove a profile
- `nota speakers merge <src> <dst>` — concatenate `<src>`'s voiceprints into `<dst>` (dedup by id), drop `<src>`
- `nota speakers reassign <vp-id> <new-name>` — move one voiceprint to another speaker profile
- `nota speakers doctor` — list low-agreement voiceprints (flagged at enrollment) and same-name voiceprint pairs scoring below 0.30, suggesting `reassign`/`delete`
- `nota enroll <history-id> <speaker-label> <name>` — enroll a stored per-speaker history clip

Enrollment hygiene: at enroll time a new voiceprint that strongly disagrees
with the person's existing prints (best same-name cosine < 0.5) warns on
stderr naming the score and is marked `lowAgreement` on the voiceprint —
never refused, never silent.

Tentative-band speaker suggestions live on history records (field
`suggestions`, `state: pending|accepted|dismissed`) — see the suggestion
verbs under `nota history` in the CLI section:

- `nota history suggestions` — list pending suggestions as tab-separated rows (record id, label, suggested name, score); header on stderr
- `nota history suggestions --recompute <id>` — recompute a record's suggestions from its stored clips against the current store (on-demand backfill)
- `nota history accept-suggestion <id> <label>` — rename the label to the suggested name (segments, clip, output markdown) AND enroll the record's clip as a new voiceprint; exit codes mirror `nota enroll`
- `nota history dismiss-suggestion <id> <label>` — clear the suggestion on this record only; store untouched

Commands exit non-zero if a referenced profile is missing. Confirmation lines
are written to stderr so stdout stays scriptable.

## Recording Storage & Deletion

XIA-436. **Nota never deletes a recording on its own.** There is no sweep, no
scheduled cleanup, no "reclaim space" path and no deletion on failure —
`grep` should keep finding none. The owner is asked to accept unbounded audio
growth, and the deal is that the figure is always visible and always
actionable by hand. The visible figure *is* the retention policy, which is why
the storage surfaces and the deletion verbs shipped together.

**The containment rule, one direction only:** deleting the transcript deletes
the audio; deleting the audio never touches the transcript. Forbidden by
construction — a cascade upward, a partial delete that leaves an assets folder
behind (the folder goes wholesale, never file by file), and any "clean up"
that removes a transcript to reclaim space.

**The exported `.md` is never deleted by Nota.** It lives outside `~/.nota`,
often beside the owner's own source audio. `nota history delete` reports its
path so the owner is told where their notes still are; the app's **Delete
record…** leaves it too, which is why the drawer row *survives* that verb —
the row is built from that file.

That sentence was **false in-tree** when it was written, and the fix is worth
recording because it was the older code that was wrong, not the rule. The
drawer row's hover **trash button** (`NotaModel.deleteHistory`, pre-XIA-436)
removed `entry.url` — the exported `.md` — on one click with no confirmation,
and then removed `<md-basename>.summary.assets` *next to the markdown*, a path
that has never existed (real assets are at `~/.nota/history/<id>.assets`). So
it destroyed the file this rule protects and left `<id>.json` +
`<id>.assets/recording.caf` behind with the row that named them gone:
unreachable from the app *and* from `nota history delete <id>`, while
`nota history storage` went on counting bytes nobody could find a handle for.
The button and the function are **gone**. Routing it through
`RecordingStore.deleteRecord` was the alternative and was rejected — that verb
keeps the `.md`, and the row *is* the `.md`, so the button would have read as
doing nothing while being the app's one unconfirmed destructive control. The
row's context menu is now the app's **only** deletion surface, and it gained
**Reveal in Finder**: removing their own exported file stays the owner's to do,
in the app that owns files.

- `nota history storage [--json]` — per-record and total sizes, oldest first.
  Read-only, with no flag that could delete. `--json` emits the whole
  `StorageSummary`, which is what the macOS Usage sheet decodes: **one
  computation**, so the sheet and the terminal cannot disagree about the
  figure. It walks the history directory itself rather than through
  `listHistoryRecords`, and both reasons are about a verb whose job is to
  *find* things: one unparseable `<id>.json` used to reject the whole
  `Promise.all` and take the verb down — **and both delete verbs with it**,
  since `resolveTargets` computes the store even for a single named id — and a
  record-driven walk cannot see an `<id>.assets/` folder no record names.
  Those **orphans are counted, named on stdout, and included in the total**;
  nothing removes them, because nothing may. A store's invisible bytes are the
  one thing a figure that *is* the retention policy may not have.
- `nota history delete-audio <id> | --older-than <age>` — removes
  `recording.caf` and clears `audioPath`/`audioBytes`. The record survives in
  full and still reads in both the app and the CLI. Three things it owes:
  the write is **atomic** (temp + rename — `writeFile` truncates before it
  writes, and a kill in between would strand the transcript this verb exists
  to preserve); it is built from the record's **raw bytes**, not from the
  object `loadHistoryRecord` normalizes, so a `status` it recomputed is never
  persisted; and it **blanks `sourcePath` when that field named the file it
  just deleted**, since `recordAudioPath` and `resolvedAudioURL` both fall
  back to it and would otherwise report a path to a file that is gone (both
  already read empty as "no audio"). A legacy record's `sourcePath` — the
  owner's own file elsewhere — is never touched. **`RecordingStore.deleteAudio`
  does all three too**, blanking included; it did not until the follow-up, so
  the same verb through the app and through the CLI left records that differed
  by one field under a header claiming they mirror each other exactly. The
  confirmation names the
  **per-speaker voice clips that stay**: they are audio of the same people,
  this verb deliberately keeps them, and "only the recording goes" misleads
  precisely the owner deleting audio for privacy.

  **A record without audio is still a record.** Deleting the audio is the one
  thing in the store that makes `resolvedAudioURL` answer nothing for a
  non-legacy record, and `HistoryRecordInfo.find` used to gate its *whole*
  result on that resolver — invisible until something could take a recording
  away, since `sourcePath` was always there to answer. So the first successful
  `delete-audio` cost the open document its history record entirely: blank
  summary slot and tag chips, every speaker chip stuck on amber "no history
  record", a name typed into a chip enrolling nothing, and
  `acceptSuggestion` / `dismissSuggestion` / `setPinned` all silent no-ops —
  while the verb's own confirmation promised the voice clips were kept *so that
  enrollment still works*. `find` needs an `id` and nothing else now, and
  `HistoryRecordInfo.audioURL` is optional. Anything that genuinely needs a
  file asks for one and handles its absence; the storage verbs never used that
  resolver at all (`keptAudioURL`, above).

  **The drawer row outlives the record it named.** Rows are built from exported
  `.md` files, "Delete record…" never removes one, and nothing else in the app
  does either — so the row is still there afterwards and its context menu can
  no longer find a record. That alert says what is true of both ways to reach
  it (deleted just now, or an imported `.md` that never had a record), names
  what is left on disk, and offers **Reveal in Finder** — the only thing that
  removes the row, and the owner's to do. It may not say "try again": there is
  nothing to retry, and after a deliberate delete it reads as a bug report for
  the thing that just worked.

  `StoredRecordRow` decodes **field by field**, for the reason
  `DictationSettings` does: the app shells out to whatever `dist/index.js` is
  on disk, and `refreshStorage` turns any decode throw into *no Storage section
  at all*. One row from a build predating `status` / `speakerClipCount` /
  `speakerClipBytes` would silently remove the figure the whole retention deal
  rests on, with a stale `dist/` as the only clue. A row with no `id` still
  throws — that is corrupt, not old.
- `nota history delete <id> | --older-than <age>` — removes the record JSON and
  its whole `<id>.assets/` folder.
- `--older-than 90d` (also `w`/`m`/`y`; 1m = 30d, 1y = 365d) **prints every id
  and the total, then asks.** No scheduled or automatic form exists. A record
  whose timestamp cannot be parsed is never selected.
- `--yes` skips the prompt and is **required** non-interactively: a run that
  cannot be asked is refused, never assumed to consent. Both verbs preview and
  confirm even for a single id.

Storage and deletion deliberately do **not** use `recordAudioPath` (TS) or
`LiveSessionPersistence.resolvedAudioURL` (Swift). Those fall back to the
absolute `sourcePath` so a legacy record can still be *played*, and that path
is the owner's own file outside the store: counting it would inflate the
store's size with bytes it does not hold, and deleting it would hand an unlink
the owner's original recording. `keptAudioPath` / `RecordingStore.keptAudioURL`
see only inside the record's assets folder, and **refuse a value that climbs
out of it** — the string is read off a JSON file and handed to an unlink, so a
record must not be able to aim the one irreversible thing this app does.
In the CLI a record with no stored audio reads **"audio not kept"**, in words
rather than as `0 B` (which would mean a recording that exists and is empty) —
once, quietly, never as an error. Legacy records simply have none. The app has
no per-record audio *column* to render, so it says the same thing in the
sentence an owner actually reads (`RecordingDeletionCopy.audioMessage` → "This
record keeps no audio"); `StorageFormat.audio` is gone, because a helper whose
only caller was its own test reads as coverage of a surface that does not
exist.

**A delete that only half happened is a failure, and is reported as one.**
`RecordingStore.deleteRecord` removes the assets folder **first**, **checks
the result**, and keeps the record JSON when it could not (an immutable flag,
a read-only parent, a file owned by another uid after a Migration Assistant
restore). A swallowed `try?` there was the forbidden partial delete happening
by construction: the record JSON went, the recording stayed, and nothing in
the store named it any more. Failing before the JSON is removed is the
recoverable order — the owner still has a row and can try again. The TS twin
gets this free (`rm(dir, {recursive: true, force: true})` throws on a real
error; `force` only suppresses ENOENT), which is why the two sides now agree.

**Discard deletes the whole record, audio included** (changed by XIA-436; it
settled-and-kept under XIA-430). That does not bend the standing rule, which
is about the *automatic* paths: Discard is an explicit press on a session the
owner is saying they do not want, and a button labelled Discard that leaves
the recording on disk is the one that lies. The other half is pinned by test —
a session that *fails* still settles and keeps everything, because nobody
chose that outcome. Two things it owes:

- **It confirms, naming the length, the bytes and the way out.** It is the
  most destructive verb in the app — a whole session's un-recreatable audio —
  and it sits between **Save Transcript** and **Try Again**, both harmless, on
  a banner it reads as dismissing. The drawer's verbs all name what goes, what
  stays and that it cannot be undone; the one that destroys the most may not
  say less. The message points at whichever alternative applies (Save
  Transcript when something was heard, Try Again when not) — which is also how
  the owner reaches the "a failed session keeps everything" path the rules
  promise. `RecordingDeletionCopy.discardMessage`, a pure string.
- **A discard whose delete did not land settles the record instead of walking
  away from it.** `LiveSessionOwner.discard` is one function for that reason:
  dropping the result and calling `release` regardless clears ownership of a
  record still saying `recording`, so `settle` can never run for it,
  `observeLiveSessionState` cannot rescue it (`isOwning` is false), the owner
  is told "Recording discarded" — and the next launch's sweep stamps it
  `failed(recording) + interrupted`, presenting as **"Interrupted"**: a fact
  that never happened, with the audio they believed they discarded still on
  disk. That is XIA-430's rule 3, and this is the one path that could break it.

**The TS↔Swift JSON contract is pinned by the CLI's own output.**
`macos/Nota/UI/Tests/Fixtures/storage-summary.json` is generated by
`scripts/storage-summary-fixture.ts` (`npx tsx scripts/storage-summary-fixture.ts
macos/Nota/UI/Tests/Fixtures/storage-summary.json`), decoded by the Swift
`StoredStorageSummary` test, and rebuilt-and-compared by a vitest — so a shape
change on either side goes red with an instruction to regenerate. The
hand-written fixture it replaced *claimed* to be field-for-field what
`--json` writes and was not: it was missing the `status` key every real row
carries.

TypeScript: `src/pipeline/storage.ts` (computation + the two primitives) +
`src/cli/storage.ts` (verbs, injectable `ask`/`write`/`out`; the real
`readline` prompt is driven by a test through a fake `process.stdin`).
Swift: `macos/Nota/App/RecordingStorage.swift` (locate, delete, discard
disposition, confirmation copy, byte formatting),
`macos/Nota/UI/RecordingDeletionMenu.swift` (the row's context menu — reveal
plus the two verbs — attached with one modifier call),
`macos/Nota/UI/StorageSummaryView.swift` (the Usage sheet section, shown
**even for an empty store**: the section carries "Nota never deletes
recordings on its own.", and hiding it until there is something to delete
shows it only to owners who have already found out).

## Custom Dictionary

Shared custom-vocabulary store at `~/.nota/dictionary.json` (schema v1), read
and written by both the CLI and the macOS dictation app:

```json
{ "version": 1,
  "terms": [ { "term": "genc2rust", "spokenForms": ["gency to rust"],
               "source": "manual", "starred": false, "addedAt": "<ISO>" } ] }
```

- `nota dictionary list` — one tab-separated row per term (term, spoken forms, source, starred, addedAt) on stdout; header on stderr
- `nota dictionary add <term> [--spoken <form>]... [--star]` — add, or merge into the existing case-insensitive match
- `nota dictionary remove <term>` — case-insensitive; exits non-zero when the term is absent

`term` is unique case-insensitively; re-adding merges spoken forms, keeps the
original `addedAt`, and leaves `starred` sticky once set. `starred` terms win
the cut when the term list is later capped for context hints. Set
`NOTA_DICTIONARY_FILE` to point both the CLI and the app at a different path
(the test suites pass an explicit path instead, so they never read it).

TypeScript: `src/utils/dictionary.ts` (store) + `src/cli/dictionary.ts` (verbs).
Swift: `macos/Nota/Dictation/DictionaryStore.swift`. The two must stay in
lockstep on field names, `version`, and the uniqueness rule.

### How dictation uses the dictionary

**L1 — recognizer bias.** At the start of every dictation session the app takes
a `ContextSnapshot` (frontmost app, bundle id, focused window title via
Accessibility) and harvests identifier-shaped tokens from the title
(`genc2rust`, `package.json`, `--no-history`). Dictionary terms plus those
tokens become `AnalysisContext.contextualStrings[.general]`, attached with
`setContext` *before* the analyzer starts. Apple caps the list at 100 short
(1–2 word) phrases: starred terms survive the cut first, then manual/learned
terms, then harvested ones. An empty dictionary and an untrusted-for-AX process
both make this a no-op — dictation behaves exactly as it did before.
The snapshot and the dictionary read are kicked off as a detached task the
instant the hotkey goes down and awaited only at analyzer setup: the AX call is
synchronous IPC into an app that may not answer, and the main actor must not be
holding the HUD and the microphone while it waits.
`macos/Nota/Dictation/ContextSnapshot.swift`.

**L2 — deterministic replacement.** After `Formatter.applyRules` and before
polish, every `spokenForms → term` pair is substituted, longest spoken form
first. The word boundary is `(?<![A-Za-z0-9]) … (?![A-Za-z0-9])`, not `\b`:
punctuation counts as a boundary, which is what lets "package json" become
`package.json` and what stops a rule for "rust" from firing inside `genc2rust`.
Substitution is a **single left-to-right pass that consumes the input**, never a
fold of each rule over the previous rule's output: with `package.json` ("package
json") and `JSON` ("json") both in the dictionary, a fold turns "package json"
into `package.JSON` — a spelling neither entry asks for. Offline and
unconditional — this is the only spelling fix available when polish is off or
fails. `macos/Nota/Dictation/WordReplacements.swift`.

**L3 — polish prompt.** `PolishClient.systemPrompt` adds a VOCABULARY block
(dictionary terms + harvested identifiers, presented as the spelling authority)
and a CONTEXT block (app name + window title). The guardrails are load-bearing,
not decoration: the context is labelled source material rather than
instructions, the model is told it is transcribing and must never answer a
question or carry out a command that appears in the text, and it must return
only the final text with no tags or fences. Without them, dictating "what's the
fastest sort?" gets an *answer* typed at the cursor. The app name and window
title are written by another app, so they are flattened to a single line and
clamped to 200 characters before interpolation — a title full of newlines would
otherwise forge a prompt section of its own. The Dictation settings footer
states exactly what leaves the machine when polish is on: formatted text,
dictionary terms, app name, window title.

**Auto-learn.** After a successful polish, `AutoLearn.candidates` diffs the
pre-polish text against the polished text and stores runs that collapsed into a
single identifier-shaped token (`gency to rust` → `genc2rust`) as
`source: "learned"` entries. Deliberately narrow — grammar, punctuation, filler
removal, ordinary word swaps, insertions, and identifier-to-identifier rewrites
are all refused, because every stored term biases future recognition. A learned
term clears a higher bar than an L1 harvest (`AutoLearn.isLearnable`): a digit,
interior case-mix, or an alphanumeric run of 2+ characters around the
punctuation, and its letters-only folding must not be a common English word —
otherwise one polish call's "email" → "e-mail" becomes permanent. At most three
terms are learned per session.

The **Dictionary** tab of the Settings window (Cmd+,) lists, adds, removes, and
stars terms against the same file the `nota dictionary` verbs use, and imports a
pasted word list in bulk (one term per line, optionally `term | spoken form`;
blank lines ignored, duplicates collapsed case-insensitively through
`DictionaryStore.merging`). A pasted list lands through
`DictionaryStore.addAll` — one read-modify-write for the whole paste, not one
per line: the pane runs on the main actor, and rewriting dictionary.json per
term froze Settings, the HUD and the hotkey path for seconds on a list of any
size. One write is also all-or-nothing, so a refused import leaves no half of
itself on disk. The Dictation tab keeps only a "Manage Dictionary…" button
pointing at it. `macos/Nota/UI/DictionarySettingsView.swift`.

## Dictation Delivery

Three ways the recognized text reaches the app being dictated into, chosen by
the **Delivery** picker (`DictationSettings.deliveryMode`, default
`.immediate`). One enum, not a set of flags — the modes are mutually exclusive
by construction. A payload written before the enum existed migrates from the old
`streamingDelivery` bool: stored `true` → `.streaming`, false/absent →
`.immediate`. That bool is still **written back out** alongside the enum, so the
migration runs in both directions — a build predating `deliveryMode` reads only
the bool and re-saves without the enum, which would otherwise strand a streaming
user on insert-on-release for good after one launch of an older build. It can
never win over the enum on the way back in: it is consulted only when
`deliveryMode` is absent.

**Immediate (default).** Everything is inserted once, on release: recognize →
`Formatter.applyRules` → `WordReplacements` → polish → one `TextInjector.inject`
into the target captured at that moment. Unchanged by the streaming work.

**Streaming (opt-in).** Sentences are typed in while the user is still talking:

```
mic → DictationTranscriber → volatile tail ───────────→ HUD rough-draft line
        └─ finalized delta → SentenceSegmenter → refine → ordered append
                                                (per sentence, concurrent)
```

- **Finality mid-session.** `AppleSpeechStream(streaming: true)` builds the
  analyzer with the `volatileRangeChangedHandler` initializer and reads each
  result's own `isFinal` instead of the teardown-time `didFinalize` flag.
  Finalized results are **deltas to append**; volatile results **replace** the
  tail — swapping those duplicates text into the user's document. Segments
  reach the controller as `Hypothesis(isSegment: true)`; every other producer
  keeps the original two-field contract, so `isSegment` defaults to false.
- **Apple engine only.** AssemblyAI realtime reports whole formatted turns
  rather than deltas, so it ignores the request and
  `SpeechStream.deliversSegments` stays false. A session that falls back to
  `SFSpeechRecognizer` also reverts to batch delivery — which is why
  `deliversSegments` is only meaningful *after* `start()` returns.
- **Sentences, not chunks.** `SentenceSegmenter` accumulates finalized deltas
  and releases only complete sentences (terminator + whitespace or end of
  finalized text; abbreviations and initials guarded). Whatever never reaches a
  boundary is released once, at stop, through the same pipeline. A 240-char
  overflow valve cuts at the last word boundary so a speaker who never lands a
  period is not silently held.
- **A fragment is not a sentence.** Each release carries how it was cut
  (`StreamingDelivery.Segment.startsSentence` / `.endsSentence`). The valve's
  mid-sentence chunk gets neither a terminal period nor a capital on the chunk
  that continues it, and it never reaches polish — polish is a sentence-level
  rewriter and hands back a sentence, capital and full stop included, for text
  that is already promised to a live document. Fragments still get the offline
  dictionary pass. The tail flushed at stop *does* end a sentence, so it is
  punctuated exactly as batch delivery would have punctuated it.
- **In order, always.** Refinement (rules → dictionary → polish) runs
  concurrently per sentence, so sentence 2's network call routinely returns
  before sentence 1's. `OrderedDeliveryBuffer` holds completions until their
  predecessors land and a single pump task serializes the writes. Text is in a
  live document and cannot be reordered afterwards.
- **Append-only.** Delivered text is never rewritten. `StreamingDelivery.appendDelta`
  computes exactly what to add (one separating space, or none if the target
  already ends in whitespace). `TextInjector.inject(_:target:mode: .append)`
  changes only the AX strategy — it reads the field's value and writes it back
  with the delta on the end, and a failed *read* falls through to CGEvent with
  the same delta rather than writing the delta as the whole value.
- **Fixed target, in every strategy.** `FocusedTarget.capture()` moves to
  session **start** and records the target's **pid**. All three strategies
  honor it: AX writes the captured element, CGEvent typing is posted to that
  pid, and the synthetic Cmd-V is posted to that pid instead of the HID tap.
  Without the pid the last two follow whatever is frontmost at *delivery* time,
  so a sentence the user started in Slack would land in whatever they clicked
  while it was being polished — and every paste- and keyEvents-forced app in
  `defaultOverrideTable` (Chrome, Slack, VSCode, terminals) takes one of those
  two paths.
- **Secure fields are re-checked per write.** A streaming session writes many
  times against one captured target, so `TextInjector.inject` re-asks
  `FocusedTarget.isSecureInputNow()` every time instead of trusting the
  start-of-session snapshot: focus inside the target app can move into a
  password field between two sentences. It can only get stricter — an already
  secure target stays refused, and an unreadable element falls back to the
  captured answer. A target that is *already* secure at session start skips
  streaming for the whole session.
- **One paste at a time.** The paste strategy's clipboard save → Cmd-V →
  restore runs through a serializing actor (`PasteInjector`) and awaits its own
  restore. Batch delivery pasted once per session so the pairs could not
  overlap; streaming delivers back to back, and unserialized the second paste
  snapshots the clipboard while it still holds the first sentence's dictated
  text and then restores *that* as the user's clipboard.
- **Degradation.** A sentence whose polish fails is delivered as its own offline
  (rules + dictionary) text and the queue keeps moving; the warning surfaces
  through the normal HUD path. With polish disabled the pipeline is still
  streaming, just rules + dictionary. Auto-learn gets a per-*session* budget
  (`AutoLearn.maxCandidatesPerSession`) because streaming polishes once per
  sentence rather than once per session.
- **A finished session stops talking.** Polish outlives the session that started
  it, and every piece of state it writes — the in-flight polish count, the
  last-result diagnostics, the auto-learn budget — belongs to the controller,
  not the session. So teardown bumps a session epoch and cancels the delivery
  queue: a stale refinement is dropped rather than surfacing session A's polish
  failure on session B's HUD, and it can never deliver into a target that is
  no longer the one the user is looking at.
- **HUD.** `ListeningView` shows a centered mic + RMS meter with the draft
  block below it, holding up to `HUDPillMetrics.draftLineLimit` `.callout`
  lines of the session. It is deliberately not part of `HUDState`: the auto-hide
  bookkeeping compares states for equality, and a line that changes on every
  syllable would make every comparison miss. The block is a **fixed** width
  (`HUDPillMetrics.draftWidth`) whenever a draft exists, so the pill widens
  exactly once — when text starts — instead of stepping wider word by word.

`macos/Nota/Dictation/StreamingDelivery.swift` holds the pure core
(`SentenceSegmenter`, `OrderedDeliveryBuffer`, `StreamingDeliveryQueue`,
delta/rough-draft/refine helpers) so the invariants are tested without a
recognizer, a network call, or an Accessibility target.

**Review (opt-in).** Polish runs exactly as `.immediate` and the finished text
goes into a small floating card instead of the target app:

- **ONE surface for the whole lifecycle** (owner call 2026-08-03 — "merge review
  dictation as part of the pill so we have only one component"). In `.review`
  the card is the *only* thing Nota puts on screen from the moment the hotkey
  goes down to the moment the owner applies or discards. The HUD pill/bar/
  prompter never appears at all. Three states, one NSPanel, no swap:
  - **Recording.** `beginCaptureAndSpeech` calls `beginOrOpenReviewCard()`
    *before* the microphone opens. With no card up that opens one, empty, with
    `isReviewRecording` set — header showing the mic dot and "Listening…", the
    live draft rendered **inside** the editor, Discard refused and the prominent
    button reading **Finish**. With a card already up it is the continuation
    path, unchanged (plan 14).
  - **Deciding.** At stop the finished text lands through the *same*
    `extendReview` a continuation uses: the editor fills, the draft suffix goes,
    the buttons become Discard/Apply. No second `present`, the same
    `PendingReview.id`, the same decision callbacks — which is what makes "one
    component" true in code and not only on screen.
  - Back to **recording** on the next press, and so on, until ⌘↩ or Escape.

  The editor is visible in every state rather than appearing at stop. It costs
  an empty box for the first session and buys the thing the mandate is about:
  the recording state and the deciding state differ by exactly one flag, so
  there is no second layout to keep in step and the text view is never rebuilt
  under the owner's caret.

  **One text box, and one button that always does something** (owner, 2026-08-03,
  two follow-ups to the same mandate). The live draft was briefly a separate
  block below the editor; it is now drawn as a dimmed suffix in the editor
  itself, because "review dictation and a preview" was two boxes for one batch.
  And the prominent button is **Finish** while a session records rather than a
  greyed-out Apply, so the trigger key is not the only way to stop. Both are
  detailed below.

  What this replaced was two surfaces in sequence — the HUD carried the first
  session's live draft, then hid, then the card appeared. Everything below about
  what a card *is* (a batch, nonactivating, one decision, target pid, epoch
  rules) is unchanged; only where the first session's live feedback renders moved.
- **Live while speaking, silent until stop.** Review runs on the **streaming**
  recognizer (`DictationSessionPlan.wantsLiveDraft`), so the card shows the same
  rough draft `.streaming` delivers — on the batch recognizer there is no
  volatile feed and the surface sat empty for the whole session. It builds no
  delivery queue: finalized segments only accumulate (`handleHypothesis` returns
  at `guard let deliveryQueue`), and the whole text goes L2 → polish → editor
  once, at stop. The streaming path's in-order refinement queue is deliberately
  not involved — nothing is delivered mid-session, so there is no order to keep.
  A session with **no** live-draft feed (AssemblyAI realtime, or an Apple
  analyzer that fell back to `SFSpeechRecognizer`) shows the header and a bare
  editor; nothing is faked into it.
- **Nothing is inserted until Apply — and Finish is not Apply.** ⌘↩ and the
  prominent button mean **Finish** while a session records: they end the
  dictation session, exactly as the trigger key's release does, and decide
  nothing. Escape and Discard stay refused throughout — throwing the batch away
  *is* a decision, and the decision is about a batch still being spoken.
- **A card that was never filled goes away.** Opening at session start means a
  press-and-release, a recognizer that would not start, or a microphone that
  would not open can leave a card holding nothing — and nothing is not a
  decision anyone can make (Apply is disabled on empty text). Every abort path
  and the empty-result branch of `presentReview` call `endReviewRecording`,
  which takes the card down **only** when the pipeline's accumulation *and* the
  editor are both empty: a silent session is no reason to destroy text the
  owner typed themselves. History follows the same rule — `openReview` records
  nothing for an empty card, and `extendReview` creates the entry the moment
  the batch first has text, so history never holds an empty dictation.
- **Nothing is inserted until Apply.** ⌘↩ applies, Escape discards, and a
  discard injects nothing at all — not an empty write. The panel is the only
  place in the pipeline where a session's text can be thrown away after it was
  recognized.
- **Apply inserts what is in the box**, not what the pipeline produced. A
  trailing newline is a keystroke, not an edit; emptying the box and applying is
  a discard by another name.
- **The panel takes key focus without activating Nota.** The owner types in it,
  so it overrides `canBecomeKey`; it carries `.nonactivatingPanel`, so it takes
  keystrokes while the app being dictated into stays frontmost (the Spotlight
  pattern). Nothing on the review path calls `NSApp.activate` — an earlier build
  did, which is what raised the home window over the target app on every
  session. Two consequences: there is **no focus to hand back** on the way out
  (the target never lost it, and the code that used to restore it is gone), and
  a fresh `FocusedTarget.capture()` at Apply time would still read the panel's
  own editor — so injection goes to the pid captured when the hotkey went down,
  and reviewed text is **refused** rather than inserted when that pid is Nota's
  own process. The panel is still the **key** window while it is up, so the
  target app's own window has to take key status back before Apply posts
  anything: `injectReviewed` waits `reviewKeyRestoreSettleNs` (80 ms) first.
  CGEvent typing and the paste strategy's Cmd-V are posted to the pid and land
  in whatever that app's key window is at delivery time — every paste- and
  keystroke-forced app in `defaultOverrideTable` would otherwise drop them into
  the gap while `lastProcessedText` claimed a success.
- **The card is checked onto the screen.** `present()` returns whether AppKit
  actually gave the panel a window device, the presenter recreates the NSPanel
  once when it did not (a dead server-side window can only be replaced — the
  bounded heal `HUDVisibilityMonitor` does for the pill), and a second failure
  drops the request and returns false. The controller then clears
  `pendingReview` and reports it: this is the one window a review session puts
  on screen, and `isReviewing` suppresses the pill while one is open, so a
  swallowed `orderFrontRegardless` no-op would be no card, no pill, no error —
  and the next hotkey press would throw the text away silently.
- **One decision per review, delivered exactly once.** The two buttons, the key
  monitor, a programmatic close and a pre-empting `dismiss()` all route through
  `DictationReviewPresenter.finish`, which *takes* the pending request before
  running its callback. Clearing the handler in the caller and invoking it after
  is the shape that broke: the callback's own "is a review still open?" guard
  then answered no, the close route's discard was swallowed, and `isReviewing`
  stayed true — suppressing the pill until an unrelated session cleared it.
- **The card, not a text box.** Same grammar as the HUD pill: one borderless
  panel, **Liquid Glass** (an `NSGlassEffectView` inset inside a 24pt transparent
  margin — a window cannot draw outside its frame), and `colorScheme` forced dark
  in both system themes. A borderless editor with no bezel or focus-ring box, and
  two chrome rows along the bottom. The buttons are drawn by the card rather than
  `.bordered`/`.borderedProminent`, which would put system light-mode chrome on a
  surface that has committed to being dark. Level is `.statusBar`, not
  `.floating`: activation used to be what raised the panel over a fullscreen app,
  and nothing does now.
- **The chrome is along the bottom and the text grows upward** (owner,
  2026-08-03: "the review, dictation, listening, number of words stuff should be
  along the bottom rows, and the text grows upwards"). Top to bottom the card is
  now editor → meta row ("Review dictation", the mic dot + "Listening…", the word
  count) → controls row (status line, Discard, Finish/Apply). Three things it
  owes:
  - **The editor is bottom-aligned**, so a short batch rests against the chrome
    and each new sentence pushes the earlier ones up — the reading line the pill
    and the prompter already pin, with the fixed edge being the row the owner is
    about to press a button in. `BottomAlignedTextView` does it by shifting
    `textContainerOrigin`, which moves the glyphs, the caret and the hit testing
    together. The two obvious alternatives were tried and measured wrong:
    `NSScrollView.contentInsets` moves the scrollable area and not a document
    that already fits its clip view, and letting the text view shrink
    (`minSize = .zero`) does not survive — the scroll view re-imposes the clip's
    size as `minSize` on every tile. `textContainerInset` is symmetric and was
    never a candidate.
  - **The whole card is the drag handle** — everything except the editor and
    the two buttons (owner, 2026-08-04: "drag from anywhere but its editor").
    The meta row alone held it until then, on the reasoning that it is the one
    part of the card that is neither an editor nor a button, so a drag there can
    never be a text selection or a mis-click on Apply. That reasoning was sound
    and its conclusion was too small: a 20pt strip on a 560×260 card, on a
    surface that is now up from the moment the hotkey goes down, reads as a card
    that cannot be moved at all — the glass plate takes no clicks and
    `isMovableByWindowBackground` is off, so pressing anywhere else did nothing
    whatsoever. The gesture therefore lives on `DictationReviewView.body`'s root,
    after the shadow-margin padding so the transparent margin is grabbable too.
    What kept the old rule safe still holds without it: the editor is an AppKit
    `NSTextView`, which consumes its own mouse-downs and never forwards them to a
    SwiftUI ancestor, so a drag starting on text still selects text; and SwiftUI
    buttons take precedence over a container gesture. One handle, not two — the
    meta row keeps no gesture of its own.
  - **The stored position is unchanged.** `ReviewPositionStore` still holds the
    card's **top-left**, because the card is still a constant size — the
    inversion moved rows, not geometry, and nothing on the card grows. A
    bottom-left anchor would only be owed if it did.
- **⌘↩ and Escape come from a local key monitor**, not `.keyboardShortcut`
  alone: `NSTextView` answers `cancelOperation:` itself, so Escape would never
  reach a SwiftUI cancel button. The monitor is scoped to the panel's own events
  and removed with it.
- **The pill stands down** while the panel is open (`isReviewing` short-circuits
  `HUDState.compute`). Two pieces of feedback for one session is one too many,
  and the pill's success snippet would claim an insertion that has not happened.
- **Learning waits for the owner.** The immediate path learns from the polish
  diff the moment it lands; review holds every diff until Apply, because until
  then the text is the model's and not the owner's. Applying learns two pairs
  through the same `AutoLearn` identifier gate: `polished → edited` (the owner
  correcting the model — the replaced spelling is stored as a *spoken form*, so
  L2 fixes it deterministically next session) and `offline → edited` (the diff
  immediate mode learns unconditionally, now endorsed). Discarding learns
  nothing. A human edit is a reason to trust a correction, never a reason to let
  prose into the dictionary.
- **A new press EXTENDS an open review; it does not cancel it** (changed
  2026-07-28 on user feedback — the old rule was "a new session cancels an open
  review, inserting nothing"). The rationale for the old rule still stands and
  is why the new one is shaped the way it is: the panel belongs to the session
  that filled it, and its target pid is that session's. What was wrong was the
  conclusion. Discarding made the mode punishing exactly when it was working —
  "one more sentence" cost everything already reviewed. So:
  - The card **stays on screen** and shows a mic dot plus "Listening…" in its
    header row (`DictationReviewModel.isListening`). The continuation session
    recognizes, L2s and polishes exactly like any other review session.
  - On stop its text is **appended to the editor's buffer**
    (`DictationReview.appended`, one space via `StreamingDelivery.joined`).
    Appended to what the OWNER has in the box, edits and all — never
    regenerated from the pipeline. The pipeline's own accumulation is kept
    separately on `PendingReview.polished` / `.offline`, because that is the
    `before` side of the diff Apply learns from and it must not see the edit it
    is being compared against.
  - **⌘↩ applies the whole batch once; Escape discards the whole batch.** While
    a continuation is recording, both are refused (buttons disabled, and
    `DictationReviewModel.apply/discard` beep) — the decision is about a batch
    that is still being spoken. `finishReview` refuses too, as the backstop.
  - **Target pid: each press re-captures, and the newest USABLE capture wins**
    (`reviewTarget(sessionTarget) ?? open.target`). The owner may have moved
    between sessions, and the app they were dictating into when they last spoke
    is the one they mean. But "newest" has to mean one Apply could actually use:
    `injectReviewed` requires a pid and requires it not to be Nota's own, and it
    checks *after* `finishReview` has taken the card down — so a capture that
    fails either test would destroy the whole batch at Apply. Both are therefore
    refused at capture time and the working target survives. Nota's own pid is
    not hypothetical: the card is nonactivating, but the owner can bring Nota
    forward (menu-bar icon, Cmd-, for the Dictionary tab) and press the trigger
    from there.
  - **Extended is not superseded.** A continuation keeps the review's `id` and
    bumps `generation`; only a genuine replacement (the card could not be
    written to, so a fresh one was opened) gets a new id. That distinction is
    what the `id` guard in `finishReview` is for: the decision callbacks the
    open card is already holding were made for the *first* session, and ⌘↩ after
    a continuation must still land. A decision from a card that was replaced
    must not. A replacement still **carries the batch** — the fresh card opens
    on `open.polished` plus the new text, and `generation` comes forward. What
    it cannot carry is the owner's editing, because the editor is precisely what
    could not be read; the pipeline's own accumulation is the best account of
    the batch left.
  - **A card belongs to the mode that can fill it.** The Delivery picker can
    move while a card is on screen, and only `.review` ever reaches
    `presentReview` — the one success-path clear of the listening flag. So the
    press is gated on the mode: in `.immediate` or `.streaming` it starts no
    continuation and *cancels* the orphaned card instead (plan 07's old rule,
    inserting nothing), and `deliver`'s non-review branch clears the flag as a
    backstop for a mode that changed mid-session. Ungated, one Settings visit
    left `isReviewRecording` true with nothing to clear it: `finishReview`
    refuses every decision while it is set, so the card took neither ⌘↩ nor
    Escape for the rest of the run.
  - Auto-learn's budget stays **per session** — each continuation is a session
    for `AutoLearn` purposes, and its polish is its own.
  - **The HUD stays down while a continuation records** (changed 2026-08-03 on
    owner feedback — the earlier rule re-admitted the live states via
    `isReviewRecording`, and the owner saw two panels narrating one microphone).
    `isReviewing` suppresses the HUD unconditionally: the card is the session's
    one surface, and its header already shows the mic dot and "Listening…"
    (`DictationReviewModel.isListening`). `isReviewRecording` still exists
    on the controller — card decidability and the header state depend on it —
    but `HUDState.compute` no longer consumes it.
    **The `.failed` exception is gone too** (same day, with the one-component
    merge): the reason for it was "a review card has nowhere to put an error",
    and the card has somewhere now — `DictationReviewModel.errorMessage`, drawn
    in the status line the footer caption already occupied. It takes that slot
    rather than a row of its own because the card's height is decided when it is
    presented, and a message that can arrive at any moment must not resize a
    card the owner is mid-edit in. The controller feeds it from `state`'s
    `didSet` (`publishReviewError`) so no failure path has to remember to.
    The split stays total because `isReviewing` is exactly "a card exists":
    when `present` fails the controller clears `pendingReview`, and the failure
    comes back out on the pill. An error always has one home, never two.
  - **The card shows the session's live draft, in the editor itself**
    (2026-08-03, twice over. First the card had to show a draft at all — with the
    pill down for the whole time a card is up, a continuation's words appeared
    *nowhere* and the card said only "Listening…". Then the owner asked why
    there were two boxes: "I'm not sure why we have review dictation and a
    preview… maybe we could merge those 2 things together, into one text box".)
    So there is one text box. While `isReviewRecording`, `handleHypothesis`
    mirrors the same two strings the HUD gets (`finalizedDraft` + `roughDraft`,
    as an `HUDDraft`) into `DictationReviewModel.draft`, and `ReviewEditor` draws
    them **onto the end of the owner's buffer** — finalized at 92% white, the
    volatile tail at 55%, the prompter's treatment — joined by the same
    `StreamingDelivery` separator the text will really be appended with, so it
    reads now the way it will read at stop. Five things it owes:
    - **Display only, and the suffix is not content.** `model.text` is the
      owner's buffer and the only string ever read back out — Apply inserts it,
      Apply's diffs learn from it, the word count counts it. The draft occupies
      the range *past* its end and is replaced wholesale each tick. The finished,
      polished text still lands once, at stop, via `DictationReview.appended`,
      and the suffix is cleared by `endReviewContinuation`, so the same words are
      never on screen twice.
    - **Read-only while recording.** `isEditable` is the one flag that
      distinguishes the two states of the box, and the coordinator refuses to
      read text back while a suffix exists as the backstop: nothing the
      recognizer drew may ever be mistaken for something the owner typed.
    - **Bounded text, fixed box.** `ReviewDraftMetrics.windowed` head-trims to
      `windowBudget` on a quantized step before anything is laid out — the feed
      ticks many times a second against a string that grows for as long as the
      owner talks. Only the suffix range is rewritten per tick, never the whole
      storage, so the owner's buffer is not re-laid-out 15 times a second. The
      card's height is **decided once, when it is presented, and never changes**:
      the separate block used to grow the panel by
      `DictationReviewView.draftBlockHeight`, and merging removed both the block
      and the resize. A surface the owner types into does not move under them.
    - **Everything macOS does *to* text is off** in that view — smart quotes,
      dash and text substitution, autocorrect, inline prediction. The box holds
      text a recognizer produced and the dictionary already corrected; a
      substitution between the pipeline and Apply would have the owner endorsing
      a spelling nobody chose. (The immediate path injects into someone else's
      field and was never exposed to this. The review card is Nota's own text
      view, so it is Nota's job.)
    - **A finished session stops talking, at the card too.** The hypothesis task
      stamps each result with the session epoch and
      `handleHypothesis(_:epoch:)` drops a stale one: `cancel()` does not unwind
      a value already handed to `MainActor.run`, so without it a dead session's
      words could be drawn on the card the next one is filling.
    Decidability is unchanged: Escape and Discard stay refused while a session
    records. The suffix says what is being heard; it says nothing about what may
    be decided.
  - **Finish: the prominent button always does something** (2026-08-03, owner —
    "when it is dictating it still shows those 2 buttons grayed out… make it some
    other button like End or Finish, so I don't have to press the globe key to
    stop"). While `isListening` the Apply slot reads **Finish** and is enabled;
    it and ⌘↩ both call `DictationReviewModel.primaryAction()`, which is Finish
    while recording and Apply when not — one expression of what the primary
    action means, for the same reason `apply()` has one. Three rules:
    - **It is not a decision.** It does not go through
      `DictationReviewPresenter.finish`, takes no pending request, and leaves the
      card exactly where it is. What it buys is the state in which a decision
      becomes possible at all. Escape/Discard stay refused throughout, and
      `finishReview`'s `isReviewRecording` backstop is untouched.
    - **It is the SAME stop path.** `DictationController.finishSessionFromCard`
      calls `endCaptureAndFinalize()` — the call the trigger key's release makes
      — so stop, polish, and `extendReview` are byte-for-byte a hotkey stop and
      there is no second teardown to keep in step.
    - **The hotkey monitor is told.** In `.toggle` activation the monitor latches
      "a session is running" from presses it saw, and it cannot see this one; so
      `finishSessionFromCard` calls `HotkeyMonitor.resetToggle()` first. Without
      it the owner's next press would send `.ended` for a session already over
      and the one after that would be the press that finally started one.
- **⌘↩ and the Apply button are one code path, and the keyboard is why it did
  not look like one** (fixed 2026-07-28). Symptom: with the card open, ⌘↩ took
  the card down and inserted **nothing**, while clicking Apply inserted fine.
  The two routes were already identical in code — the key monitor and the
  button both end in `finish(.apply(model.text))` → `finishReview` →
  `injectReviewed` — so no amount of reading the branch explained it. What
  differed was the keyboard: on the shortcut route the owner's ⌘ is
  *physically down* when injection runs 80 ms later. A `CGEvent` built from a
  `CGEventSource` inherits that source's modifier state, and
  `.combinedSessionState` includes the physical keyboard, so
  `TextInjector.tryCGEventInject` posted its Unicode-payload keystroke tagged
  ⌘. A ⌘-tagged key-down is a shortcut: the target routes it to key-equivalent
  dispatch and never inserts the payload, silently, while `lastProcessedText`
  claims success. That is not an exotic path — every terminal in
  `defaultOverrideTable` is forced onto `.keyEvents`, and the AX strategy (the
  one modifiers cannot touch) is exactly the one those apps skip, which is why
  it reproduced for the owner and not in a plain Cocoa text field. It stops
  there, though: the `.paste`-forced bundles build their Cmd-V with
  `flags = .maskCommand` on purpose and were never affected — reading the fix
  as covering Chrome or Slack sends the next investigation to the wrong file.
  Two fixes,
  because either alone leaves a hole: `TextInjector` now assigns `flags = []`
  to both events it builds (a keystroke carrying text is never a shortcut,
  whatever the keyboard is doing), and `injectReviewed` first awaits
  `ModifierClearance.wait()` — a bounded 500 ms poll of
  `CGEventSource.flagsState(.combinedSessionState)` — because the target app's
  *own* idea of the modifier state comes from the real keyboard and no flag we
  set on our event can correct it. Bounded on purpose: a stuck modifier may
  delay a session's text, never swallow it. The key monitor now calls
  `model.apply()` / `model.discard()`, the same call the buttons make, so
  "what Apply means" is written down once.

- **The card is draggable, and it keeps its own position.** The **whole card**
  is the handle (`DragGesture` on `DictationReviewView.body`'s root →
  `DictationReviewPanel.dragChanged/dragEnded`) — the title row until the chrome
  moved to the bottom on 2026-08-03, then the meta row, then everything but the
  editor and the buttons on 2026-08-04, when the owner reported the card would
  not move: with the pill suppressed for the whole of a `.review` session, a
  20pt strip was the entire target and every other press did nothing at all.
  Still not the window background: this card contains a text view and a
  drag inside it has
  to select text, and AppKit's background drag reports nothing — "the owner
  chose this position" is precisely the fact that has to be remembered. The
  editor is what makes a container gesture safe rather than reckless — an AppKit
  `NSTextView` consumes its own mouse-downs and never forwards them to a SwiftUI
  ancestor. The drag
  is measured against `NSEvent.mouseLocation`, never the gesture's translation,
  because the gesture's coordinate space is anchored to the window the drag is
  moving. `reposition()` honours a validated pin and returns early, exactly as
  the HUD's does.
  It stores through **`ReviewPositionStore`, not `HUDPositionStore`** — same
  mechanism, different value, deliberately. The HUD stores the pill rect's
  *bottom-center*: the bottom edge is what its upward growth pins, and the
  horizontal centre is the only x that survives a switch between a 200pt pill
  and a 600pt prompter. This card is a constant-size surface — the draft is
  drawn inside the editor, so nothing grows it — and its meaningful anchor is
  simply the **top-left**. That survived the chrome moving to the bottom: a
  bottom-left anchor would be owed only if the card grew upward, and it does not
  grow at all. One shared point would mean dragging either
  surface moved the other, through an anchor that means nothing on the far side.
  Restoring validates rather than trusts (`ReviewPanelLayout.validatedTopLeft`):
  a point no current screen contains is dropped and the automatic placement
  under the focused window is the self-heal; a point a screen still holds is
  clamped so the **whole** card stays on it.

`macos/Nota/Dictation/DictationReviewPanel.swift` holds `DictationReview` (the
pure apply/discard core), the panel, and the presenter behind
`DictationReviewPresenting` so the controller's review branch has no window
server in it. `DictationController.deliver` is internal for the same reason: it
is where the branch begins, and with a stub presenter injected it drives apply,
discard and a superseded review from a unit test.

## Dictation HUD Styles

Three shapes for the same panel, chosen by the **Style** picker in the Dictation
tab's HUD section (`DictationSettings.hudStyle`, default `.pill`). A new key with
no migration: a payload written before it existed, or carrying a value this build
does not know, decodes to `.pill` — which is what its owner was looking at.

- **Pill (default).** The capsule, and since the growing draft landed the
  *tallest* of the three: a header row (mic + meter) on top, and under it up to
  `HUDPillMetrics.draftLineLimit` (8) lines of the whole session, head-truncated
  so the oldest lines go first. It grows **upward with its bottom edge pinned**
  (see below), which is why the header is on top: the bottom edge is the anchor,
  so the newest line is the one that holds still and the header rides up.
  It is still the style everything else is measured against, but "unchanged" is
  no longer the claim — `HUDPillBaselineTests` pins its geometry outright
  (meter-only height, the constant draft-block width, one `draftLineHeight` per
  line, and that no draft can outgrow `HUDPillMetrics.maxCardHeight`, which is
  what `reposition()` reserves). The bar and the prompter still carry their own
  surface modifier (`HUDSurface`) and their own meter (`HUDCompactMeter`) rather
  than refactoring the pill's into something shared.

**All three styles are Liquid Glass, and none of them draws it.** The material is
an `NSGlassEffectView` (`GlassBackingView`, laid out at the card rect — the
window frame inset by the 24pt shadow margin) with the SwiftUI hosting view above
it. A SwiftUI `.glassEffect`/`.liquidGlass` inside a transparent panel was
measured to render as a flat blur: it refracts only its own hierarchy, and a
HUD's hierarchy is a glyph and a line of text. What is left in SwiftUI is the
content, the padding (which is what every pinned fitting size measures, so not
one baseline number moved), and the **semantic** wash and stroke for `.warning`
and `.error` — the neutral fill and the hairline are gone, because the plate
carries its own rim and a second one is the doubled outline the toolbar pills
already taught us to stop drawing. The plate is tinted dark
(`GlassBackingView.tint`): these panels sit over arbitrary content and their text
is white, and untinted regular glass over a bright background is the washed-out
failure the flat dark body was originally chosen to avoid. Corner curvature is
restated for the plate by `HUDGlassMetrics.cornerRadius` (a capsule for the pill,
capped at 20 for the two states that wrap to a second line, each other style's own
radius), since an AppKit view cannot take a `Shape`. The plate takes no clicks
(`GlassPlateView.hitTest` returns nil) — the HUD claims every point for its drag
handle and the review card's editor has to keep text selection.
- **Bar.** A fixed 520×40 strip: mic dot + meter left, one 13pt line right. Its
  one promise is that it **never** changes size — the content view is a hard
  `.frame(width:height:)`, so long text truncates into the lane instead of
  widening it, and `HUDStyle.animatesGrowth` is false for this style alone so
  `DictationHUDPanel.update` skips the animation group entirely. The line is
  tail-anchored (`.truncationMode(.head)`), and a leading gradient mask makes
  older words read as *leaving* rather than as being chopped off.
- **Prompter.** A 600pt card: header (mic dot, meter, "Dictating", live word
  count) over the session's text, finalized at full opacity and the volatile
  tail dimmed to 55% white. It grows **upward** from a 3-line floor to a
  6-line cap (`HUDPrompterMetrics`, arithmetic and testable), animated by the
  one authority — the window frame in `DictationHUDPanel.update`. Past the cap
  the body is not a `ScrollView`: the text is laid out inside a clipped,
  **bottom-aligned** frame, so the newest line is pinned to the bottom edge and
  older ones slide out of the top. Auto-following by construction, with no scroll
  animation racing the window's and no scroll position to keep in sync — and
  there is no `ScrollView` anywhere in the card, so a drag over its body moves
  the panel and disturbs no scroll position.
  Three things the card owes that construction:
  - **It measures a bounded window, not the session.** `HUDPrompterMetrics.windowed`
    head-trims to `windowBudget` characters before anything is measured or laid
    out. Six lines is all that can be seen, and the HUD is re-rendered on every
    66 ms RMS tick against a string that grows for as long as the user talks —
    measuring and laying out all of it put an unbounded main-actor cost on a
    feed that ticks 15 times a second. The budget is more than twice what six
    lines can hold at the font's narrowest glyphs, so the *clamped* line count
    (the only thing the height depends on) is unchanged. The head is quantized
    to `windowStep`, because greedy wrapping starts wherever the window starts
    and a head that advanced by a character per tick would re-wrap the visible
    lines on every one of them.
  - **What it draws is what it measured.** The two `Text` runs come from
    `HUDPrompterMetrics.runs`, which carries the separator
    `StreamingDelivery.joined` used — never an unconditional `Text(" ")`. Apple's
    volatile results sometimes arrive with their leading space attached, and the
    card would then draw a double space it had sized itself without.
  - **It is placed with its growth room already reserved.** `reposition()` asks
    `HUDStyle.reservedCardHeight` for the tallest the card can get and, via
    `HUDPanelLayout.pillOriginY`, keeps the fully grown card 8pt inside the
    screen — the room reserved **above** it, since that is where it grows.
    Without the reserve, `clamped` shoves the grown frame back down and the
    bottom edge upward growth pins walks away one line at a time. That is
    exactly what "the pill grows downward again" was: the direction was right,
    but `.pill` still declared itself a style that cannot grow and reserved
    nothing. Both growing styles reserve now; only the bar (a hard 520×40)
    reserves nothing.

**The draft feed is split at the source.** The controller publishes
`finalizedDraft` (everything the recognizer has finalized) alongside `roughDraft`
(the volatile tail); `HUDDraft` carries both at full length. The **bar** reads
`HUDDraft.boundedTail` — `StreamingDelivery.roughDraftTail` over the volatile
tail *alone* — because it is one line and always will be. The pill outgrew that
feed when it started growing: it reads `HUDDraft.growingText` (every finalized
line, then the in-flight tail), because a tail-only feed blanked every earlier
sentence each time a turn finalized. The prompter reads both halves separately
so it can dim the volatile one. That is the reason for the split: a
120-character merge cannot be un-merged. `HUDDraft` stays out of `HUDState` for the same reason the rough draft
always did: the auto-hide bookkeeping compares states for equality.

**A style switch is not growth.** `DictationHUDPanel` remembers the style it is
showing and sets the frame *without* animating when the style changes, because
the controller repositions immediately afterwards: an animation still in flight
means `reposition()` reads an interpolated frame and is then overwritten by the
animation's destination — the off-center panel the reposition exists to prevent.
The controller asks the panel which style is on screen rather than keeping a
second copy of the bookkeeping; a recreated panel starts on `.pill` whatever the
setting has been saying.

**No style appears in `.review` at all** (2026-08-03). The old non-goal read
"the prompter does not morph into the review card (stop hands off to the
existing card)"; it was written when the HUD carried a review session's first
draft, and the owner has since asked for one component. It is now *stronger*
rather than reversed: there is nothing to morph, because the card is on screen
from the press and `HUDState.compute` returns `.hidden` for every controller
state while `isReviewing`. The three styles are `.immediate` and `.streaming`
only. Everything else in this section — the pill baseline, the bar's fixed
frame, the prompter's cap and reserve — is untouched by that.

The rest of the non-goals, still true: a style that is *about* text
(`HUDStyle.isAboutLiveText`) shows none when the session runs the batch
recognizer, which happens two ways — `.immediate`, and any mode on AssemblyAI
realtime. The Dictation pane names whichever one applies via
`HUDStyle.liveTextCaveat`, asked of `DictationSessionPlan` rather than of the
delivery mode alone: a pane that knows only about `.immediate` leaves an
AssemblyAI user staring at a permanently blank prompter with no explanation.

## Model Settings

Non-secret model preferences live in `~/.nota/settings.json` (schema exactly
`{ "transcription": { "model": "..." }, "summary": { "model": "..." } }`).
Secrets never go here — API keys stay in `~/.nota/config`. Precedence for each
model is **CLI flag > settings.json > key-aware default chain**.

Summary models are auto-admitted weekly from `models.dev/api.json` through an
allowlist (mainline chat models only: gpt-5.x, gemini flash/pro, deepseek v4+).
Transcription model ids remain statically curated; the OpenRouter shortlist and
the CLI engines are hand-curated in code (see Namespaced Model Ids and CLI
Engines below).

- `nota models list` — print the effective summary catalog (id, provider, label, source) as tab-separated rows; `source` is `cache`/`baked` for auto-admitted entries, `curated` for the OpenRouter shortlist, and `cli` for a subprocess engine
- `nota models refresh` — force a fetch from models.dev, showing added/removed ids
- `nota settings list` — effective model + source (settings.json vs default); tab-separated rows on stdout, header on stderr
- `nota settings get <path>` — print the effective value for a dot-path (`transcription.model` or `summary.model`)
- `nota settings set <path> <value>` — validate against the registry and persist; invalid model exits non-zero listing valid ids
- `nota settings unset <path>` — remove the key, reverting to the default

The summary default is key-aware: `deepseek-v4-flash` if `DEEPSEEK_API_KEY` resolves → `gpt-5.4-mini` if `OPENAI_API_KEY` → `gemini-3.6-flash` if `GEMINI_API_KEY` → error listing the three options. No CLI engine is in that chain and none may be added to it, however installed and working the binaries are — the error names API models only. If a configured summary model is absent from the catalog (retired), it warns once and falls back to the chain.

Transcription model ids (static):
- `universal`, `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`

Summary model ids (auto-admitted; run `nota models list` for the current set):
- Example: `gpt-5-mini`, `gpt-5`, `gpt-5.1`, `gpt-5.4-mini` (OpenAI); `gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-3.6-flash` (Gemini); `deepseek-v4-flash`, `deepseek-v4-pro` (DeepSeek)

Summary model ids (curated OpenRouter shortlist, `src/openrouter.ts`):
- `openrouter/anthropic/claude-sonnet-5`, `openrouter/anthropic/claude-haiku-4.5`,
  `openrouter/moonshotai/kimi-k2.6`, `openrouter/qwen/qwen3.7-max`,
  `openrouter/z-ai/glm-5.2`, `openrouter/meta-llama/llama-4-maverick`

Summary model ids (CLI engines, `src/cli-engines.ts` — never a *polish* model):
- `claude-code/sonnet`, `claude-code/opus`, `claude-code/haiku`
- `codex/gpt-5.6-sol`, `codex/gpt-5.6-terra`, `codex/gpt-5.6-luna`, `codex/gpt-5.4-mini`

The macOS Settings window (Cmd+,) exposes the same pickers plus masked API-key
management; it mirrors the registry in `macos/Nota/App/ModelRegistry.swift`.
Its Models tab's **summary** picker offers those seven under a "Subscription
CLIs" group, appended after the catalog, and pins one to the same
`~/.nota/settings.json` any other model goes to — see CLI Engines.

## Namespaced Model Ids

ADR 0002. A model id is one string that fully names a summarizer, and it is
either **flat** (`gpt-5-mini`) or **namespaced**
(`openrouter/anthropic/claude-sonnet-5`). Provider is still never stored and
never chosen — it is *derived*: the first path segment for a namespaced id, the
registry's lookup for a flat one. An id whose namespace names no provider Nota
has is **refused**, not rescued by whatever `provider` field arrived with it —
that fallback would reintroduce exactly the invalid state ADR 0001 removed.

Two ids exist per model and they are not interchangeable. `ModelEntry.id` is
canonical: it is what settings.json holds, what history and usage records name,
what a picker shows. `ModelEntry.wireId` is that id with the provider namespace
stripped, and it is the only thing that goes on the wire — OpenRouter wants
`anthropic/claude-sonnet-5` back, not its own name in front of it. Persisting
the wire id would orphan a record from the registry entry that named it.

The split is only worth what its call sites honor, and every one of them is a
place a canonical id 400s: `config.summaryWireModel` (not `summaryModel`) for
the summary call *and* the preflight canary — the canary is a real request, and
sending the namespaced id there blocks every run at the gate that exists to be
cheaper than the transcription it guards — and `entry.wireId` for every
`summarizeTranscript` / `summarizeOnly` / `generateTags` call in
`src/cli/enrich.ts`. What is *recorded* alongside each of those stays
`entry.id`: `makeSummaryUsage` takes the canonical id.

Every registry/catalog entry also carries an **execution kind**: `http` (an
OpenAI-compatible endpoint plus an API key) or `cli` (a local subprocess, no key
— `claude-code/*` and `codex/*`, see CLI Engines). Surfaces that cannot host
a subprocess filter on the kind **structurally** — `httpModelsForTask` in TS,
`ModelRegistry.httpModels(for:)` in Swift, which is what the dictation polish
picker and `PolishClient` use. Matching on id prefixes is explicitly not the
mechanism: a catalog refresh must not be able to leak a subprocess engine into
a per-sentence streaming path.

An unrecognized execution kind resolves to *nothing*, not to `http`, and the
entry is dropped — **per entry**, on both sides (`sanitizeCatalog` in
`src/catalog.ts`, a non-throwing element wrapper in `ModelCatalog.init(from:)`).
A build that cannot name a kind must not assume it is safe to run in-process,
and one row written by a newer Nota must not blank every model picker in the
app. Same rule for an unknown namespace.

Dropping happens to the **catalog**, not to the picker's view of it:
`effectiveCatalog()` sanitizes before merging the curated shortlist, and
`ModelCatalogLoader.effective` does the same through `ModelCatalog.sanitized()`.
Filtering only inside `summaryModelEntries()` is what broke — `contains(_:)`
asks a *different* question of the same array (is this stored preference a live
pin or a zombie?), so an id no picker offered and no request could be built for
still answered "valid", and the app and the CLI disagreed about the user's own
settings.json.

`src/model-id.ts` and the `ModelID` / `ExecutionKind` types in
`macos/Nota/App/ModelRegistry.swift` are the two halves; they must stay in
lockstep on the grammar, the provider set, and the kinds.

## OpenRouter

A fifth provider (`OPENROUTER_API_KEY`, base URL `https://openrouter.ai/api/v1`),
reached through the same OpenAI-compatible client as Gemini and DeepSeek. What
differs is admission and pricing.

- **Admission is by hand.** models.dev's weekly auto-admit never sees
  OpenRouter — 300+ ids would drown every picker. Six frontier slugs are curated
  in `src/openrouter.ts` (mirrored in `ModelRegistry.openRouterModels`; the TS
  file is the source of truth) and **merged into the effective catalog at read
  time**. That is what makes them refresh-proof: `nota models refresh` rewrites
  the auto-admitted cache, and the cache has never contained them. A real cache
  entry with the same id wins over the hand-written stub.
- **No pricing is stored.** OpenRouter routes one slug across providers whose
  rates differ and change without our knowing, so `cost` is *absent* — which is
  not zero. `computeSummaryCost` returns null and `nota usage` prints
  "refer to OpenRouter" where a figure would go, keeping those runs out of the
  unknown-cost tally (that tally flags gaps in Nota's own data, not a price that
  lives on someone else's dashboard). Out of the tally is not out of the
  **reckoning**: an unpriced row adds 0 to the total, so the totals line carries
  a `+` ("at least") and a `N runs not in total (…)` footnote. A cost report
  that quietly understates the bill is the one failure mode it may not have.
- **The output cap is `max_tokens`, not `max_completion_tokens`.** OpenRouter
  *drops* a parameter the route it picked does not support rather than erroring,
  so OpenAI's spelling is worse than a rejection there — the cap silently would
  not apply and only the bill would say so. `usesMaxTokensParam` decides from
  the **base URL** rather than the model id, because the id that reaches
  `summaryTokenLimit` is the *wire* id and has had the segment naming its
  provider stripped off; the endpoint the request is addressed to is the last
  thing that still names it, and it is the party that decides which parameters
  it accepts. `callGPT` reads it back off the client it already built, so the
  parameter key and the destination cannot drift apart.
- **Defaults are untouched.** The key-aware chain stays
  `deepseek-v4-flash > gpt-5.4-mini > gemini-3.6-flash`; no OpenRouter model
  joins it, and `--provider` is unchanged. Choosing one is always explicit.
- Slugs were verified against a live `GET https://openrouter.ai/api/v1/models`
  (no auth needed) rather than recalled — re-verify before editing the list, and
  keep them undated so they do not rot on a vendor's schedule.

## CLI Engines

ADR 0003 (amended 2026-07-28). `claude-code/*` and `codex/*` are summary models
that are not endpoints: Nota spawns the `claude` or `codex` binary already
installed on the machine. No API key, no base URL — the CLI authenticates with
its own login and the work is billed to the owner's subscription, which is the
whole point. They are a **summary** path only (including its sectioned
>100k-token mode, which spawns once per section plus the roll-up) and never
reach **dictation polish**, which is latency-bound and stays `http`, enforced by
the execution-kind filter rather than by convention.

- **The macOS app may pin one as its summary model.** The original ADR said
  "never in the macOS app"; its rationale was latency, which is a claim about
  polish and not about the app. The app's summary path is `nota-app-run.sh` —
  the TS pipeline, i.e. the CLI path — so a `claude-code/*` pin in the shared
  settings.json runs exactly the subprocess `nota` would. The Models tab's
  summary picker therefore offers the seven under a "Subscription CLIs" group
  after the catalog (`ModelRegistry.cliEngineModels`, ordered; the id set is
  *derived* from that list so the two cannot drift), with a footer naming what
  they need and what pays for them. They are deliberately **not** `ModelEntry`
  values in Swift: a CLI engine has no `ModelProvider`, and inventing one would
  put a "paste your key" row in the API Keys tab (which is built from
  `ModelProvider.allCases`) for a login that lives in the CLI's own config.
  That is also why nothing can leak into the polish picker — `httpModels(for:)`
  filters `ModelEntry` values, and there is no such value to miss.
  They are still not catalog rows: `ModelCatalog.contains` answers "is this a
  live auto-admitted/curated entry". The question "may this be pinned" is
  `ModelCatalogLoader.isValidSummaryPin`, which is the union, and `isZombie` is
  its negation. Asking `contains` for both is what made the pane call a working
  pin "no longer available" *and* made `effectiveModel(for: .summary)` quietly
  substitute the default chain for it. The app probes no binaries and shows no
  CLI rows in API Keys — a missing binary or a stale login fails at the summary
  step with the error the CLI path already raises.

- **Never a default.** They are absent from the key-aware chain and may not be
  added to it, however installed the binaries are. "Free but slow" must never
  win a default — a summary that takes minutes of local wall time is a choice
  the owner makes explicitly with `-m` or `nota settings set summary.model`, and
  the "no summary model available" error names API models only. Offering an
  installed CLI as the rescue for a missing key would make it the effective
  default on every machine without one.
- **The prompt goes on stdin, never argv.** A transcript is megabytes and
  `ARG_MAX` is not; quoting one into a command line is a bug waiting for the
  first apostrophe. Both CLIs read a prompt from stdin when none is given as an
  argument. The prompt itself is byte-identical to what the HTTP path sends —
  same builders, same instructions.
- **Nothing is inherited.** stdin is a pipe Nota writes and closes (never
  `inherit`: a CLI that finds a TTY waits for a human who is not there), the cwd
  is a scratch directory, and every `CLAUDE*`/`ANTHROPIC*`/`CODEX*` variable
  plus every provider API key is withheld. `CLAUDE_CONFIG_DIR` and `CODEX_HOME`
  are the two exceptions — they say where the CLI's own login lives, and
  `CODEX_HOME` survives only so the login can be *found*; what the child is
  finally handed is the jail described below. Leaking
  `ANTHROPIC_API_KEY` would bill a metered account for a run whose cost line
  says "included w/ subscription"; the report would be a lie and the invoice
  would be the first anyone heard.
- **No ambient instructions reach the model, and the cwd is not what does it.**
  A scratch cwd stops only *project* discovery. Both CLIs load a **user-level**
  guide from the home directory whatever the cwd — `~/.claude/CLAUDE.md` and
  `$CODEX_HOME/AGENTS.md`, plus the skills, plugins and hooks their config turns
  on — so left alone, the owner's personal agent guide is prepended to every
  meeting summary. Measured from `tmpdir()` on 2026-07-28: the baseline argv
  quoted this machine's global guide back verbatim on both engines. The two
  engines need different mechanisms.
  - **Claude Code: `--safe-mode`.** Its help lists exactly what it turns off
    (CLAUDE.md, skills, plugins, hooks, MCP, custom commands) and says auth,
    model selection and tools "work normally". `--bare` disables the same things
    and was **rejected**: it also makes auth "strictly ANTHROPIC_API_KEY or
    apiKeyHelper", i.e. the metered account this whole path exists to avoid.
  - **Codex: a private `CODEX_HOME`.** There is no flag for it.
    `--ignore-user-config` drops `config.toml` and its plugins and hooks but
    **not** `$CODEX_HOME/AGENTS.md` — measured, as was `-c
    project_doc_max_bytes=0`, which does not reach it either. So
    `prepareCodexHome` builds `~/.nota/codex-home` containing one entry:
    `auth.json`, symlinked to the real one. The login is the only thing from
    that directory a summary run is entitled to. The link is **recreated every
    run**, because a token refresh that writes-and-renames would replace it with
    a regular file — stranding the refreshed token in Nota's directory and
    leaving a credential copy behind. The directory is persistent rather than
    per-call (codex bootstraps a model cache into any home it is given, and a
    sectioned summary spawns once per section). Failing to build it is **fatal**:
    running under the owner's whole agent configuration is the bug, so it may not
    be the fallback for it. `--ignore-user-config` stays as the cheap half of the
    same job. `--ignore-rules` was rejected — execpolicy `.rules` only restrict
    what a shell command may do, so ignoring them loosens a rail the owner set
    rather than removing an instruction.
- **Failure is hard and no HTTP model is substituted.** Binary missing from
  PATH, missing login, non-zero exit, timeout, or a clean exit with no answer —
  each throws, naming the binary, the fix, and for a timeout how long it waited.
  Falling back would silently bill a provider the user did not configure. A
  blank answer is a failure too: it would be parsed into a summary and written
  over the user's notes. So is a *non*-blank one that is really a login
  complaint — both CLIs report an expired login on the happy exit path, printing
  one line where the summary should be, so the auth sniff runs on exit-0 output
  and not only on empty output. It is bounded to short output
  (`CLI_AUTH_SNIFF_MAX_CHARS`) because the sniff matches "401" and
  "unauthorized" and a meeting is allowed to have been about an HTTP status.
- **The timeout is generous and scaled.** Three minutes plus 3s per 1000 prompt
  characters, capped at 30 minutes. These engines are minutes slow by design.
- **Preflight probes, it does not call.** For a `cli` summary model the check is
  binary-on-PATH plus `--version`; a canary completion would cost minutes of
  wall time on every run, for a gate whose purpose is to be cheaper than the
  transcription it guards. Presence is verified and a stale login is not — the
  detail line says so, and an unauthenticated engine fails at the summary step
  with an error naming the login. The reported version is the first non-blank
  line of **stdout**; stderr is kept in its own buffer and used only if stdout
  said nothing. Interleaved, the answer is whatever arrived first, and startup
  noise arrives first — an exported `NODE_OPTIONS` (which `sanitizedEnv`
  deliberately keeps, being neither a credential nor session state) makes
  `nota config` print a deprecation warning as the CLI's version.
- **Cost is a note, not a figure.** No `cost` is stored, so `computeSummaryCost`
  returns null and displays print "included w/ subscription" through the same
  `costNote` mechanism OpenRouter uses. Those runs stay out of the unknown-cost
  tally (that flags gaps in Nota's own data) and appear in the
  `N runs not in total (…)` footnote. Token counts are estimated from the text —
  a subprocess reports none — and the usage entry says `estimated: true`.
- `nota config` gains a CLI-engine block: binary, resolved path and version, or
  "not found on PATH". `nota models list` marks their source `cli`.
- Flags and ids were verified against the installed binaries on 2026-07-28
  (`claude` 2.1.220, `codex-cli` 0.144.0): `claude -p --safe-mode --model
  <alias> --output-format text --tools ""`, and `codex exec -m <slug> --sandbox
  read-only --skip-git-repo-check --ignore-user-config --color never -` under a
  jailed `CODEX_HOME`. Codex slugs come from the CLI's own listed model set;
  Claude Code uses the tier **aliases**, which track the vendor's rotation where
  a dated name would rot. Re-verify before editing either list — including the
  isolation, which is a claim about two CLIs' behavior and not about ours:
  ask a cheap model to quote its own instructions and check that nothing from
  `~/.claude/CLAUDE.md` or `$CODEX_HOME/AGENTS.md` comes back.

## Model Catalog (self-updating)

Summary model ids, labels, limits, and pricing are sourced from a local cache
(`~/.nota/models-catalog.json`) that is auto-refreshed from `models.dev` weekly
in the background. A baked snapshot ships in-repo as the fallback. To see the
current catalog: `nota models list`. To force a refresh: `nota models refresh`.
The cache feeds cost computation for usage tracking.

## The Ground

What the app is drawn *on*. XIA-442 built the field, XIA-443 the ink tiers,
XIA-446 gave each view its own colour. `macos/Nota/UI/Field/`.

The ground is a **64×36 image scaled to the window**, which is not a
compromise: every feature in it is a soft blob hundreds of points across, so
the upscale *is* the blur. `.interpolation(.high)` is load-bearing — at `.none`
or `.low` the same buffer reads as a grid of squares, which is what this
approach looks like done wrong. Six colour seeds ride a divergence-free curl
current; the whole frame is advected along that current and relaxed 7% back
toward the seeds' target every step, which is what makes it flow rather than
crossfade. It runs at **20fps, deliberately not 60** — nothing in it moves fast
enough for a third frame between two others to resolve.

### A family per launch, a ground per view (XIA-446)

The launch draws a **`GroundFamily`** — a chord of three of the sixteen
palettes, one per **`GroundRole`** (`home`, `recording`, `transcript`) — and
holds it for the process. It used to draw a single palette, and the two things
that were then in tension are both true now: the ground is still different
every morning, and the three views are still visibly different from each other.

**The morph is free, and that is the whole design.** The field already relaxes
toward its target every step, so a *target* whose hues move is followed over
about a second and a half on the current it is already flowing on. Nothing
interpolates pixels and nothing cross-fades two images. What produces a cut is
**`reprime()`**, not changing colour — which is why the engine's original "one
ground per launch, never re-rolled" note was aimed at the wrong noun. So
`FieldSimulation.morph(to:push:)` moves the wash hue, the six seed hues and
`push`, and may **never** reprime, rebuild the seeds (that snaps all six home
and restarts the composition at minute zero), or touch `elapsed` (that is the
session's warmth). `Seed.hue` is `var` for exactly this: a seed keeps where it
has drifted to and only its colour moves. Hues travel the **short way round**
(`GroundMorph.hue`) for the reason `GroundWarmth.rotate` does — the long arc
crosses the far side of the wheel and every intermediate is mud. The morph
**lands** rather than approaching forever; an exponential never arrives, and a
field still doing hue arithmetic for a switch that finished a minute ago is
work nobody asked for.

`testAViewSwitchMorphsAndDoesNotCut` is the assertion that holds all of it:
the first frame after a switch moves **0.54** against a whole-morph travel of
**42.90** — 1.3%. Anything that reprimes takes that number to most of the way
and the test goes red.

**Under Reduce Motion a switch paints once instead of morphing.** The morph is
advanced by `step`, and a Reduce Motion engine never steps again — without the
one-frame landing the previous view's ground would stay up until the next
launch.

**The toolbar draws no material, in every phase.** This reverses a deliberate
earlier decision — the bar used to stay borderless at rest and regain its
scroll-edge material once content scrolled beneath it — and the reversal is
not a change of taste. That rule was written when the transcript pane had
nothing behind it, so the material appeared over the system window background
and read as a toolbar. With the ground running the full height of every phase,
the same material is a hard horizontal seam: washed-out field above the line
and full field below, at a boundary that has nothing to do with the picture.
What the material bought — telling scrolled content apart from the chrome —
the ground buys differently, since the toolbar's controls are Liquid Glass
capsules that refract what is under them and therefore read as floating *on*
the ground rather than needing a plate to sit on. Same argument as the
recording cluster (XIA-445).

**Which view is which is declared by the call site**, never inferred:
`FieldBackground(role:)`. Home is `.home`, the live session `.recording`, and
**both** the transcript and the in-progress run are `.transcript` — a run is
the transcript arriving, and the pane becomes the document without the window
changing, so a ground that switched underneath at the moment the text landed
would read as a second event. Two surfaces are briefly mounted at once while
`ContentView` cross-fades its phases, so the last `onAppear` wins, which is the
incoming view; nothing clears the role on the way out, or the outgoing view
would drag the ground back with it.

**Readability is `push`'s job and `flatten` is fixed at 0.40** — measured, not
simplified. Push moves the value band away from the ink; flatten collapses the
band itself. The luminance-span floor is 5.0 points and 0.40 already measures
5.3 on `ink` light, so every raise sweeps below it (0.45 → 4.8, 0.50 → 4.3,
0.62 → 3.2) and a transcript ground that "calmed down" by flattening would be
the field turning back into flat paint. `transcript` therefore takes **push
0.97** — the last value with margin, since 1.00 measures *exactly* the floor —
buying the ink 1.1 points of extra lightness separation in light mode and 1.3
in dark. `home` and `recording` keep 0.90: nothing about those two asked for a
change. There is deliberately **no `GroundRole.flatten`**, and
`testNoRoleRaisesFlatten` is what the next person to want one has to argue
with.

**The seven families were chosen by measurement.** All 560 triples were scored
on 65% base-hue arc plus 35% the mean arc between their seed hues — the seed
term is what stops `tidepool` and `quarry`, which share a base hue of 190° and
carry very different families, from being scored as one colour. Minimum
separation 45 (below it the three views read as the same room, which loses the
point), maximum 98 (above it they are three unrelated colours rather than a
chord — the top-scoring triple in the whole set is 108.6 and looks like three
different apps), and no two families sharing more than one palette (without it
the search returns four near-copies of the same violet). Roles inside a chord
are assigned by rule too: each ground is scored on how far its seeds sit from
its own base wash, and the busiest becomes `home` (the front door, which can
afford to be loudest) while the quietest carries the transcript.

**Families overlap on purpose** — a palette is a colour and a role is a job, so
the same colour holds different jobs in different chords (`kiln` records in
Riverbank and carries the transcript in Sunfall). Requiring the sixteen to
partition into threes would have meant retiring a palette for arithmetic's
sake. Seven families cover fourteen of the sixteen: **`meadow` (44°) and
`vellum` (50°) are drawn by nothing**, being near-twins of `orchard` (60°) and
`kiln` (30°) which are. That is a finding about the sixteen rather than a gap
to paper over, and they stay in `GroundPalette.all` because the ember proof
walks that array.

**The ember rule needed no new proof**, and two separate attempts to defend it
here were wasted work worth recording. Separation from ember holds by
**saturation**, not hue — the ground tops out near 38% (light) / 50% (dark)
against ember's 80% — which is why `kiln` can sit at 30°, inside the ember hue
band, from the first frame at warmth zero.
`FieldEngineTests.testTheGroundNeverComesNearEmber` already walks all sixteen
palettes at four warmth points and requires ΔE > 20, so every ground in every
family inherits it. A per-view *hue rotation* would have needed a fresh proof;
re-using the existing sixteen does not.

### What the ground costs, and the trap it is built around

`FieldBackground` is **three flat siblings** and only `FieldImageLayer` holds
the `@ObservedObject`, so a published frame re-evaluates an `Image` in a
`GeometryReader` and nothing else. The first cut hung the grain off the
observing struct as an `.overlay`, which made `CraftNoiseLayer` — a `Canvas`
whose renderer closure is not comparable — redraw ~476 ellipses across the full
window twenty times a second, having previously run **once, ever**. That is
`SessionMeterFeedView`'s shape and the XIA-432 trap for the third time: the
*rate* of a publisher and the *breadth* of its observers multiply, and the fix
is always to narrow the observer rather than to slow the publisher.

**The wash is underneath, always — not an `if`/`else`.** A branch meant the
first body evaluation drew the cool periwinkle wash (`engine.image` is nil
until `onAppear` runs, which is *after* the evaluation that installed it) and
the first frame then swapped the subtree outright: a hard cut with no
crossfade, because a `_ConditionalContent` branch change is not an animation.
Keeping the wash as the floor makes the arrival a fade, makes a CoreGraphics
refusal degrade to the surface that was there before rather than to a hole, and
costs one static gradient. The floor is the wash **gradient**, not
`CraftWashBackground`, which carries its own grain layer and drew it twice.

The engine is a `static let` **nobody else observes**, refcounted by viewers
(both production surfaces can be up at once), stopped when the app is occluded
(`onDisappear` does not fire for minimise, ⌘H, or another Space — and Nota is
left running all day), and **inert under XCTest**, so view tests see the wash
they were written against rather than whichever ground the process drew.

## The Document Surface

What a finished transcript looks like (XIA-441, merged with the Details panel
2026-08-19, ADR 0006). `macos/Nota/UI/MainPaneView.swift`,
`DocumentHeaderView.swift`, `SummaryRailView.swift`, `RichTextViewer.swift`,
`MarkdownRender.swift`.

**The pane is the transcript, and everything else is behind one button.** Top
to bottom it is a header holding the **title alone**, a hairline, and the
reading column. The subtitle, the speaker chips, the record's fact strip, the
tags and the summary all live in **one panel** — `SummaryRailView`, opened by
the one **Details** button (`info.circle`) in the bottom-right local cluster
beside Share. Not two surfaces, not tabs, not a second card: the details block
is the first thing inside the panel's existing `ScrollView`, above a hairline,
above the summary half.

The panel is taller for it, and it still clears the cluster by construction:
its bottom padding is the cluster's own diameter plus a gap plus the ordinary
inset, so the surface can never land on the button that opened it however much
it holds.

The intermediate design is worth naming because it is what the merge deleted:
for two days the header carried an info *toggle* opening a `DocumentInfoCard`
overlay while a separate Summary button opened the rail. `DocumentInfoCard` and
`DocumentInfoToggle` are **gone**; `DocMeta.subtitle(facts:)` outlived them
(the one-duration-per-surface rule, below).

**A header that cannot change height cannot oscillate.** The metadata used to
fold away on scroll, so the header changed height, so it changed the scroll
range that had decided it should fold — a state change driven by a value it
alters. The owner saw it as the transcript **shaking**, and only on short
documents, which is the signature: a long document has range to spare and never
clamps. Two thresholds plus a range floor (`DocumentHeaderCollapse`) damped it;
moving everything but the title out of the header **removed** it, and all of
that arithmetic is deleted. `RichTextViewer.onScroll` reports the offset alone
now; the range existed for the collapse and has no reader.
`testTheHeaderIsOneHeightWhateverTheDocumentCarries` lays the header out bare,
with a subtitle and tags, and with twenty tags, and requires one height.

**Opening is free; generating is not.** The Details button starts nothing — the
old dual-purpose click (a press with no summary used to spend a model call
*and* open the rail to watch it) is gone with the `plus` glyph that promised
it, and so is its `.disabled`: a tag run is no reason to lock the owner out of
their own speaker chips. The only way to start a summary is the **Generate
summary** button *inside* the panel, in the slot where the narrative would be.
A record with no narrative is the ordinary resting state of a transcript-only
meeting, so that slot is a state and not a failure; a failed generation lands
in the same slot with the message above a button reading **Try Again**, rather
than in a second block with a second retry one state apart. Edit and Regenerate
are **absent** there rather than greyed out — two dead controls above the live
one, one of them naming an object that never existed, read as a summary that
was tried and failed.

**One dot, two claimants.** `DocumentInfoBadge.waiting(chips:isSummaryOutdated:)`
lights the button's amber dot when a speaker chip holds a suggestion **or** the
summary is stale, and `DocumentInfoBadge.label(_:isGeneratingSummary:)` is the
one string `.help` and `.accessibilityLabel` both read, naming whichever is
waiting — both, when both are. A chip holding a suggestion is Nota *asking*
("Speaker 2 → Kenny Kim? 0.62"), and it asks once, when the transcription
lands; behind a button nobody opens, that question is never seen. The subtitle,
the fact strip and the tags never earn a dot — they state, they do not ask —
and an **unnamed** speaker does not either, since nothing is waiting on an
answer. The label also carries the in-flight summary, because the button's own
`accessibilityLabel` replaces the `ProgressView` inside it: the ring is pixels,
and without the clause a non-sighted owner is told "Details" whether or not the
run they started is still going. The dot rides outside the button's shape —
the glass would blur it, and a badge may not resize the control it is on.

**A document with no history record keeps its button and its panel.** The
cluster used to draw the button only when `enrichment.record != nil`, so an
imported `.md` had no way in at all and its own subtitle, chips and tags were
unreachable. That gate is deleted. The panel draws what the document has and
omits what it does not: the fact strip is a record's facts and is absent with
the record, the summary half is replaced by one line saying there is nothing
behind this document to summarize, and `hasDetails` keeps the hairline from
being drawn under nothing. Nothing about a document may disappear because of
where it was opened from.

**The panel may not say anything it cannot support.** Three rules, each of them
a false statement the merge made reachable:

- **A tag run is not a summary run.** The fork that swaps the summary half for
  the in-flight row branches on `activity == .summarizing`
  (`SummaryRailView.summaryIsInFlight`), never on `!= .idle`: the tags row is
  four rows above it in the same panel now, so one press on Generate tags used
  to replace the narrative — or an open editor holding an unsaved draft — with
  a progress row reading "Generating tags" under a heading reading SUMMARY,
  while the tag row drew its own spinner. It is the same predicate the Details
  button's ring uses, so the button and the panel agree about what is running.
- **"No record" and "not read yet" are different answers.**
  `SummaryRailView.summaryHalf(hasRecord:isResolvingRecord:)` is three states.
  `NotaModel.loadChips` clears the record synchronously and reads the real one
  off disk in a detached task (`EnrichmentController.beginRecordLookup`), so
  every recorded transcript passes through `record == nil` on open. The notice
  waits for the lookup, and it states the **absence** only — it opened
  "Imported file —" for one day, which is a claim about provenance that
  `record == nil` does not support: a failed transcription leaves a document in
  the pane with no record behind it either.
- **A failure belongs to the row it happened in.** The controller has one error
  channel and both halves of the panel draw out of it, so the failure carries
  `EnrichmentController.errorField` (an `EnrichmentField`, not the *activity*
  it used to be). `addTag` / `removeTag` go through the same `applyEdit` a
  summary edit does, which left the kind nil, which passed the summary slot's
  `!= .tagging` filter — so a failed tag add printed under the summary and
  relabelled its button "Try Again", one press from a model call for an
  operation that was not a summary.

**One duration per surface.** `DocMeta.subtitle(facts:)` drops the markdown's
`**Duration:**` figure whenever a fact strip beneath it states the same length.
The two disagree by construction — `durationMinutes` is rounded up, so an
18 min 42 s meeting exports "19 minutes" while the strip reads `18:42` off
`durationSeconds` — and drawing both put two roundings of one fact four points
apart on the feature chosen so the moment and the document could not disagree.
The rule lives on `DocMeta` because the surface has moved three times (header,
info card, panel) and the rule never moved with it.

**The dismissal policy governs the whole panel and may not be weakened.**
Someone who opened it to read a speaker's name must not be able to lose an
in-progress summary edit on the way out: every close — the ×, click-outside,
Escape, a record switch, a phase leave — runs `requestSummaryRailDismissal`.
The panel is visually modal (an invisible full-window backdrop makes the window
inert to clicks), so it carries `.accessibilityAddTraits(.isModal)` and the
backdrop is `.accessibilityHidden` — otherwise the assistive cursor goes on
walking a transcript and a Details button nothing can reach. Generate summary
takes `.defaultAction`, since it is the one control that spends money and the
panel takes no initial focus.

**The reading column.** The document path had no measure cap at all —
`widthTracksTextView` plus a 48pt inset means a 1400pt window draws
140-character lines. The cap is on the **text container**, not the insets (a
wider inset moves the column left; a container width centres it): 34em of the
reading face, ~74 characters, inside the 45–75 band. Body is 18.5pt at
`GroundInk.Tier.reading` (alpha 0.80) — the owner's pick, and defensible
because ≥18pt is WCAG **large** text, which drops AAA from 7.0:1 to 4.5:1.
Every colour in `MarkdownRender` comes from `GroundInk.nsColor(_:)`, a dynamic
`NSColor` resolved per appearance at draw time; a baked colour would strand the
document on a theme switch. Zero `labelColor`/`separatorColor` remain, and
`testTheRenderedDocumentUsesNoSemanticColours` fails on any that come back.

`parseDocumentMeta` **stops at the first `## `** and enumerates lines rather
than splitting the document into an array first. That is not tidiness: the
panel reads it two to four times per body evaluation and its own `TextEditor`
writes an `@Published` on the model it observes, so a parse that materialized
the whole `.md` would re-split a long meeting on every keystroke of a summary
edit — the publisher-rate × observer-breadth trap this file already records
three times, arriving as parse cost rather than view cost.

## The Recording Surface

What a live session looks like while it is running (XIA-431 the accent,
XIA-432 the pane, XIA-445 the cluster it is now). One arrangement, three
components, and one reserved colour: the ember still means the microphone is
open and nothing else. The cluster's two action capsules are blue and red,
which are colours for *actions* — see the cluster section for why the red is
allowed to sit near a warm accent now and was not before.

### The ember

`CraftTokens.ember(_:)` — `#d1662a` light, `#e8823a` dark — means exactly one
thing: **the microphone is open.** It is not a brand colour, it does not vary
by meeting-vs-memo, and nothing outside the recording components may draw with
it. A second consumer would make it mean "Nota" instead of "we are capturing"
and the signal would be gone. It is warm because everything else here is cool:
the Craft Glass ground is a periwinkle/indigo wash and `primaryBlue` is the
confident action, so the accent is the one warm thing in the room. The dark
value is lifted and desaturated on purpose — `#d1662a` over the smoky wash
reads as brown rather than as a live signal. `emberWash(_:)` is the same hue at
10/16% for a ring interior or a meter lane; it is a glow, not a fill, and body
text keeps its contrast over it.

### The three components (`macos/Nota/UI/RecordingAccent.swift`)

- **`SessionMeter`** is the live level, and it is **information**. It is the
  only proof on screen that the microphone is actually open and hearing
  something. Two variants (`.compact` in the cluster and in the island,
  `.tall` for a surface that has the room) rather than a free `height`, because
  a meter whose bar count
  varies continuously has no baseline to pin. It has a **floor**: a silent room draws
  the minimum bar height, never nothing, since a blank meter and an absent
  meter look the same.
- **`SessionRing`** is the breathing ember circle, and it is **decoration**. It
  carries no state the owner needs; it breathes because a live session should
  feel alive. **No surface draws it today** — the column's ring went with the
  column, the bar's dot went with the bar, and the cluster's Essential timer
  capsule has neither. It survives for two reasons worth naming rather than
  letting it look like dead code: it is the positive control for the ember pixel
  probe (`testTheProbeSeesTheEmberItIsLookingFor`, without which
  `testTheIdlePaneDrawsNoEmber` would pass against a blank canvas), and it is
  the other half of the Reduce Motion asymmetry below, which is a rule about
  what a live microphone may look like and not about one shape.
- **`SessionTimer`** is the elapsed clock — mono, tabular, and the single most
  legible thing on the surface, because in a conversation what matters is the
  indicator that things are flowing.

### Why the timer's metrics are a type and not a view

`SessionTimerMetrics` is pure arithmetic (`text`, `form`, `fontSize`,
`plateWidth`) for the reason `HUDPillMetrics` and `HUDPrompterMetrics` are: the
numbers are then asserted without a window server, a hosting view or a
microphone. The decision it holds is the **step**: `mm:ss` draws at the
caller's size and `h:mm:ss` at 72% of it, and the change happens exactly once,
at the hour. It is deliberately not a fitted or auto-shrinking font — those
re-measure on every tick and the digits would breathe with the seconds.

The half that makes the step free is `plateWidth`, which reserves the wider of
the two forms **up front** and is therefore independent of `elapsed` by
construction. That is what makes "the plate keeps its width" a fact about the
code rather than a hope about the metrics: crossing the hour re-sizes the
glyphs inside a box that never moves, and `hh:mm:ss` is reserved rather than
`h:mm:ss` so a tenth hour cannot ask for a second step.

### Reduce Motion is answered differently by the two, on purpose

`RecordingMotion` writes it down once, and the asymmetry is the whole point:

- The **meter keeps moving** under Reduce Motion — with a plainer curve, no
  spring overshoot, but it moves. Freezing it would not calm the interface; it
  would make a live session and a wedged one look identical.
- The **ring stops breathing** and holds at a steady scale and opacity. Nothing
  is lost: the meter is already saying the thing the ring was dressing up.

`reduceMotion` is deliberately **not** a parameter of
`SessionMeterMetrics.barHeights`. The heights are what the microphone is doing,
and that is not a motion preference; only the curve between two readings is.

### Reduce Transparency changes the material and nothing else

The capsules degrade to opaque system materials through the existing
`liquidGlass` branch, and the hairline and the shadow stay — they are constants
on `CraftTokens`, not properties of the glass. Nothing moves: every number in
`RecordingPaneMetrics` is a constant or is measured once from a font, and
neither kind reads an `@Environment` value, so there is nothing for an
accessibility setting to reach. Reduce Motion reaches exactly one thing here
and it arrived with XIA-447: the Pause capsule grows into the word "Paused", so
`RecordingMotion.pauseAnimation` returns nil and the two widths are a cut. That
is the only transition on the surface. And the ember is untouched — it is a
function of the colour scheme alone.

**Stop's red survives the degrade, and the mechanism is what makes that true.**
`Glass.tint(_:)` is a property of the *effect*, and the degraded branch swaps
the effect for `.regularMaterial` and takes the tint with it — a tinted-glass
Stop would go grey precisely where the material goes away, which is the failure
the bar's solid ember fill existed to prevent. So `RecordingCapsuleTint` draws
the colour as the capsule's own background **over** its glass: the glass is what
degrades, the colour is not. Both action capsules use that one mechanism, and
`testStopStaysItsOwnRedOverAnyBackdrop` renders Stop over white and black and
looks for red in both. What it deliberately does **not** assert is that the two
readings are equal, which the bar's opaque Stop could promise: 62% over glass is
the owner's number and the whole reason the capsule refracts at all, so it does
vary with the ground. What it may not do is stop being red.

### The cluster (XIA-445, replacing XIA-444's bar; `macos/Nota/UI/RecordingPane.swift`)

Three Liquid Glass capsules — **timer, Mark, Stop** — horizontally centred near
the bottom of the live-meeting view, floating **over** the transcript rather
than sitting in the layout above it. The transcript takes the whole window.

A fourth capsule (**Moments**, opening the marker list in a popover) was built
and then ruled out by the owner on 2026-08-11: see "Mark carries the tally, and
nothing on the surface lists moments" below.

It was a ~288pt trailing column (XIA-432), then a full-width bar (XIA-444), and
each step handed the transcript back an axis the indicator had been charging it
for: first width, now height. The column's argument survives all of it — in a
conversation what matters is the indicator that things are flowing — which is
why the cluster still carries the clock and the meter. What did not survive is
spending any of the reading surface on it. **The bar was measured and rejected**
against a live prototype the owner drove on 2026-08-11: it still took a band off
every window for a clock, a meter and two buttons, and it *grew* that band on
hover.

What went with the bar, and each removal took a class of arithmetic with it:

- **The hover bloom** (the 22pt → 58pt clock, `SessionHoverArea`,
  `barHeight(bloomed:)`, `RecordingPaneLayout`, `RecordingMotion.bloomAnimation`).
  The cluster is one size. Two reserved plates, an animation between them, and
  an AppKit tracking area installed to trigger it are all gone — deleted, not
  left unreferenced.
- **The rail.** `RecordingPaneMetrics.railWidth` drawn with `.ground(.rail)` was
  the *ink* argument (a measured 1.2:1 tier rather than a `Divider()`) and that
  argument is untouched; what it separated is simply no longer two stacked
  things. A hairline under a floating capsule is a rule between a surface and
  itself.
- **The ghost/solid button pair.** `RecordingGhostButtonStyle` and
  `RecordingStopButtonStyle` were shaped for a full-width row with text labels.
  One `RecordingCapsuleButtonStyle` replaces both — icon only, one tint
  parameter — so the action capsules differ by a colour and a glyph and nothing
  else.

Left to right: the clock (with the meter), Mark, Stop. The column's
top-to-bottom order, laid on its side, for the third time. The two action
capsules are `SessionClusterAction.allCases` — glyph, label, tooltip, tint,
whether the tally rides on it — and the cluster draws that table with a
`ForEach` and dispatches on the case in one `perform(_:)`. That is not
tidiness: "which control does what" is exactly what shipped wrong, and as a
table it is a fact a test reads rather than closures a rendered window would
have to be driven to discover. A stopped session refuses **both** of them, so
there is no per-action `requiresALiveSession` any more — the one case that
answered it differently is gone, and a property that can only say `true` reads
as a question the surface is still asking.

- **They are SIBLINGS, never nested.** Apple's guidance is that Liquid Glass
  inside Liquid Glass is silently auto-converted to a vibrant fill — so a
  capsule drawn inside a capsule is not a *doubled* rim (the toolbar-pill
  failure one section up), it is a rim quietly **overridden**, with nothing on
  screen to announce it. One `GlassEffectContainer` holds them all so their
  lensing merges instead of refracting once per plate, and it is given the **same**
  spacing the `HStack` uses (`RecordingPaneMetrics.capsuleGap`): the container's
  spacing *is* the merge distance, and two numbers would merge the plates at a
  gap the eye does not see or fail to merge at the one it does.
- **SwiftUI `.glassEffect` is correct here**, via `craftGlassPanel`, and that is
  not a contradiction of the floating-panel rule in Key Design Decisions. That
  rule is about an `NSPanel`: SwiftUI glass refracts only its own hierarchy, and
  a HUD's hierarchy is a glyph and a line of text, which is why the dictation
  surfaces need `NSGlassEffectView`. This cluster is inside the main window and
  the morphing field it refracts **is** in its hierarchy. Do not reach for
  AppKit here.
- **Every capsule is exactly the same height, and the number is measured.**
  `RecordingPaneMetrics.capsuleHeight` is `capsuleContentHeight + 2 *
  capsulePaddingV`, and the content height is the max of the 30pt clock's
  reserved line box, the compact meter's tallest bar, and the action glyph's
  line box measured from `actionMeasuringFont` — never a typed literal. A row of
  capsules is one object made of parts; three heights reads as three things that
  happen to be near each other. The precedent is XIA-444's, and it is a warning:
  `controlRowHeight` was *typed* 40 against a row that laid out at 41, so the
  bar reserved 64 and drew 65 with every geometry test in the file green through
  it. So the cluster owes both halves —
  `testTheCapsuleHeightIsDerivedFromTheTallestThingACapsuleHolds` for the
  derivation and `testEveryCapsuleDrawsExactlyTheHeightTheClusterReserves` for
  the laid-out view, plus
  `testTheThreeCapsulesAreTheSameHeightAsEachOther`, because capsules
  could each agree with the same wrong constant. That one measures the three
  distinct *faces* — the timer capsule and the two tints of
  `RecordingCapsuleButtonStyle`.

  **The row's *width* is pinned the same way**, and it is the only thing that
  can see a capsule the surface should not have. `allCases` says what the row
  holds and a `ForEach` draws it, so the table and the drawing agree with each
  other by construction whatever is in the table.
  `testTheClusterIsExactlyThreeCapsulesAndTwoGaps` composes the reservation from
  the three faces plus two `capsuleGap`s and compares it against the laid-out
  cluster; the faces come from `SessionCapsuleCluster.capsule(_:)` (internal for
  the reason `perform(_:)` is), since a test that rebuilt the label would
  measure its own copy of the markup. On the four-capsule build it reads
  351.0pt drawn against 275.0pt reserved.
- **The timer capsule is clear glass: the meter and the clock, and nothing
  else.** That is the owner's "C · Essential", chosen over three fuller variants
  on the same day, and each omission has a reason. The ember **dot** went
  because the meter proves the same thing and proves it harder — a dot is lit
  whether or not anything is being heard, and a meter with a floor is the only
  thing on screen that can tell a live microphone from a wedged one. The **kind
  line** went because a kind is relabelable after Stop and forbidden from
  changing anything visual, so during a session it is a word that never moves
  and never does anything. The clock is 30pt through `SessionTimerMetrics`,
  which still reserves the wider of `mm:ss` / `hh:mm:ss` up front, so the step at
  the hour re-sizes glyphs inside a box that never moves (XIA-431, unchanged).
- **Mark carries the tally, and nothing on the surface lists moments** (owner,
  2026-08-11). Mark is `CraftTokens.primaryBlue` at
  `RecordingCapsuleTint.strength` (62%) over the glass — the app's existing
  "confident action" colour, used for actions, at ΔE 132 from the ember where no
  confusion is possible — draws `bookmark.fill`, runs `onMark`, carries ⌘K
  (`.keyboardShortcut`, named in `.help` and in the accessibility hint as
  `Mark ⌘K`, `RecordingPaneCopy.markHelp`), and shows the moment count beside
  the glyph past zero.

  **Reviewing moments during a recording is deliberately not possible.** You are
  recording, not browsing, and a control whose whole job is to read back what
  you already flagged is not something the surface over a live transcript owes
  you. Reading a mark back belongs to **XIA-433** (moment markers end to end),
  which is where a mark gets a meaning worth reading — an auto-title from the
  surrounding transcript, persisted on the record and carried into the summary.
  Two things were rejected to get here: a **fourth capsule** (Moments,
  `list.bullet`, opening `SessionMarkerList` in a popover — it shipped, and the
  owner ruled it out the same day), and hanging the list off a **long-press or
  right-click of Mark**, which hides a whole affordance behind a gesture nothing
  on screen names, on the one surface whose other rules are that nothing moves
  and nothing is hidden. `testNoCapsuleOpensTheMarkerList` pins it on the table,
  because a capsule that is not a case cannot be drawn, disabled, tinted or
  given a shortcut.

  **The tally survived when the list did not**, and that is the one cost weighed
  against the fourth pill. With no count and no list, ⌘K is a button with no
  observable effect at all — the count is the only feedback a press has, so it
  moved onto the capsule that produces it (`carriesMarkerCount == .mark`).

  `SessionMarkerList` is **kept in the file with no caller**, and says so in its
  own comment: XIA-433 wants exactly this row (a timestamp, and a label beside
  it when there is one), and its decisions — a popover rather than hairlines
  down the transcript, its own `ScrollView` — were already argued. It produces
  no unused-symbol warning (checked on the Debug build), and
  `testNoCapsuleOpensTheMarkerList` lays it out in both states rather than
  leaving it to rot untouched.

  What all of this is downstream of is worth keeping: the cluster's *first* cut
  had one capsule doing both jobs and it did the **wrong** one — the visible,
  Mark-looking control opened the list, and `onMark` survived only on a
  zero-sized, fully transparent, `accessibilityHidden(true)` button tucked into
  the row's `.background`. So a mouse or trackpad user could not flag a moment
  at all, a VoiceOver user could not either, and ⌘K was named in no label, no
  tooltip and no hint anywhere.
  `testEachCapsuleRunsItsOwnJobAndNoOtherCapsulesJob` drives `perform(_:)` — the
  same call every capsule's button makes — because walking the accessibility
  tree cannot answer it: SwiftUI publishes no tree for a hosting view in an
  unhosted test bundle, with or without a window (measured 2026-08-11, every
  label came back empty, Stop's included).

  **The tally is reserved from zero**, not past the first mark. The count itself
  is nil at zero and never "0" (`RecordingPaneCopy.markerCount`), and the plate
  it sits on (`markerCountWidth`, two digits) is drawn empty until there is one.
  Both halves are the same rule — a control may not move under the pointer — and
  only the second half shipped: the plate and its `spacing4` used to appear out
  of nothing on the first ⌘K, and because the cluster is *centred* that widening
  splits across both sides and stepped **Stop** ~11pt right, under the pointer
  most likely to be aiming at it. Master's full-width bar was immune by
  accident, through a `Spacer(minLength:)` that pinned the trailing edge; a
  centred cluster has no such spacer and has to reserve instead.
  `testTheNumberOfMomentsNeverMovesStop` renders the cluster at 0, 1, 9 and 10
  moments and compares the drawn leading edge of the red capsule. It also
  *derives* that edge rather than only guarding that it is right of centre: a
  centred row's trailing edge less Stop's own laid-out width. The row got one
  capsule shorter when Moments went, and a derivation moves with it where a
  hand-typed number would have had to be loosened.
- **Stop is red, icon only, and the loudest thing on the surface.** The owner
  chose red over the ember **with the measurement in hand**: CIE76 ΔE from
  `systemRed` to the ember is 38.5 dark / 33.1 light, closer than the moving
  field is ever allowed to get (41.3, pinned by the field tests). That objection
  was real and is recorded rather than argued away — and what defuses it is the
  Essential timer capsule the same call chose. With the ember dot gone, the only
  ember left in the cluster is the meter's thin moving bars, which no filled
  capsule can be read as: the collision the number describes is between two
  *fills*, and there is now only one. `CraftTokens.stopRed`.
- **The transcript reserves the cluster's whole footprint** — the owner's
  "Reserve space", over reading through the refraction (which would bet the
  ink solve covers ink *under glass* on the ground, and it does not) and over
  the cluster fading while text arrives (a moving thing at the edge of vision
  during the one activity that should feel calm). It comes off the **scroll
  view's own frame**, and that is the half that matters — it shipped as scroll
  *content* padding on the `LazyVStack`, which buys nothing at all here.
  `scrollToNewest` pins the newest row with `anchor: .bottom`, i.e. aligns that
  row's bottom with the bottom of the **visible region**, and 83pt of padding
  that follows the last row in content space is simply offset the scroll view
  never needs to reach: the newest line came to rest flush against the window's
  bottom edge and the one before it sat behind the glass, every session, with a
  green reservation constant beside it. Only a frame / safe-area /
  `contentMargins` inset moves where that anchor lands.

  A **frame** inset among those three, because the number has to be checkable:
  measured 2026-08-11, `.safeAreaInset(edge: .bottom)` leaves the backing
  `NSScrollView`'s frame, clip view and `contentInsets` all at full height, so
  no test in this bundle can tell it from the padding that was the defect.
  Shrinking the scroll view reads as 317 of 400 and is asserted as such — and it
  is the more literal reading of "reserve space" anyway, since nothing is drawn
  under the glass even mid-scroll. `transcriptBottomReserve` is composed from
  the constants the cluster is *placed* with (`capsuleHeight +
  clusterBottomInset + clusterTranscriptGap`) rather than typed a second time,
  and `testTheTranscriptReservesTheClustersWholeFootprint` asserts the
  composition **and** measures the laid-out scroll view's visible region. Its
  predecessor compared `NSHostingView.fittingSize` with and without the reserve,
  which content padding satisfies perfectly — a test adjacent to the thing that
  mattered, which is how all of this stayed green. A failed session's transcript
  reserves nothing: nothing floats over it.
- **The kind reaches the surface as one word, in the idle state.** The cluster
  draws no kind at all now, so `RecordingPaneCopy.kindLine` is read only by
  `idleView` — and it stays in `all(kind:controls:)`, which
  `testAMemoAndAMeetingDifferByExactlyOneString` still walks unchanged. That
  promise is about the *pane* rather than about one of its states: the whole of
  the difference between a memo and a meeting is still one string, and it is
  still that one. `markTitle` / `stopTitle` survive as the accessibility labels
  of the two icon-only action capsules, and `markShortcut` / `markHelp` as
  Mark's hint and tooltip — still strings the surface puts in front of someone,
  which is why they are still covered.
  (That sentence used to claim all of `markTitle` / `markShortcut` / `stopTitle`
  were labels and tooltips of *two* capsules; only `stopTitle` was true of the
  code. `markTitle` was on a button hidden from accessibility, and `markShortcut`
  was drawn nowhere at all.)

  `markersHeading` / `noMarkers` came **out** of `all(kind:controls:)` with the
  Moments capsule. That list is every string the surface can put on screen, and
  no surface draws those two now — they belong to `SessionMarkerList`, which has
  no caller. They stay as constants beside the view that reads them, not in the
  promise about what an owner sees.
- **The transcript lays out a speaker column the pipeline does not fill yet.**
  `LiveTranscriptLine.speaker` is nil today, `LiveTranscript.blocks` already
  groups consecutive lines by it, and a turn draws the name above its text when
  there is one. Realtime speaker labels are a known unresolved follow-up; the
  grouping is not waiting to be written, it is waiting to be fed, and the day it
  is the transcript gains names and not one number in `RecordingPaneMetrics`
  moves. The volatile tail is a line like any other — it continues the turn it
  belongs to and differs only in being drawn at the `timestamp` ink tier.
- **…but the grouping may not cost the laziness, so the drawn model is flat.**
  `LiveTranscript.rows` turns the blocks into one row per line plus a header row
  where the speaker changes, and `LiveTranscriptView` puts those rows **directly**
  in its `LazyVStack`. A `LazyVStack` defers only its direct children: nesting a
  block's lines in an inner `VStack` made the whole session **one** child —
  because every line's speaker is nil today, there is exactly one block — so a
  90-minute meeting built and measured 800 `Text` views with
  `.fixedSize(vertical:)` on every render pass, on screen or off. Master had put
  each segment straight in the stack. The gutter timestamp belongs to whichever
  row opens a turn and the rest reserve the cell and draw nothing in it, so
  nothing steps left; the inter-turn gap is paid by the row that opens one,
  since a flat stack has no blocks left to space apart.
- **The row model is memoized against the transcript** (`LiveTranscriptRowCache`).
  Building it is O(all segments), and a render the transcript did not cause —
  a clock tick, anything that invalidates the window — must not pay for it. The
  key is the segment count, the last segment's id, the partial, and the whole
  seconds of `elapsed` (all `elapsed` reaches is the volatile line's gutter
  timestamp, which is drawn to the second).
- **There is one clock.** `LiveMeetingFormat.duration` delegates to
  `SessionTimerMetrics.text`. The gutter timestamp beside a transcript line,
  the time on a marker row and the clock in the cluster name the same
  instant, and two implementations of "the same instant" is a disagreement
  waiting for a rounding change.
- **Only a live session wears the cluster** (`LiveMeetingControls
  .showsRecordingPane`). A failed session gets the banner over whatever it
  heard: the cluster is the indicator that a session is *flowing*, and a live
  meter over a dead microphone is the exact lie the meter exists to make
  impossible. **The idle state owes the same rule and did not keep it**: it drew
  a breathing ember ring above the Start button, over a closed microphone, in
  the state every owner sees before every recording — the state that teaches
  them what the colour means. It draws none now, and `testTheIdlePaneDrawsNoEmber`
  renders the pane and scans the pixels, because "there is no ember on screen"
  is not a claim a constant can carry.
  The idle and failed states keep `.liquidGlassButton()` deliberately: the
  capsule vocabulary is the *recording surface's*, and those are not recording
  surfaces.
- **`LiveMeetingSession.level`** republishes `MicCapture.rmsLevel` rather than
  exposing the capture engine, which would hand a view `start()` and `stop()`
  as well. Two things about it are load-bearing:
  - **It is its own object** (`MicLevelFeed`, held as a plain `let`), not a
    `@Published Float` on the session. The tap delivers ~45 buffers a second and
    the session is observed by `ContentView` *and* `LiveMeetingView`, so a level
    on it invalidated the entire window body — toolbar, drawer overlay,
    transcript — 45 times a second, which is three times the rate CLAUDE.md
    already flags as an unbounded main-actor cost for the HUD prompter, against
    a much larger hierarchy. Only `SessionMeterFeedView` observes the feed.
    `MeterPublishGate` throttles the writes on top of that: never faster than
    66 ms (the HUD's own tick), never for a move too small to see, and — the
    escape the movement gate needs — any difference at all after 500 ms, or a
    level decaying toward silence in sub-threshold steps would wedge the meter
    at the last loud reading.
  - **It answers the microphone only while the audio is being kept**
    (`LiveMeetingSession.meterFollowsMicrophone`). On the AssemblyAI path
    `stop()` sits in `.stopping` for up to the 5s watchdog with the tap still
    installed, while `handlePCMBuffer` drops every buffer at its own guard. So
    the owner pressed Stop, kept talking, watched the ember meter answer their
    voice, and reasonably concluded those words were captured; they reached
    neither `recording.caf` nor the socket. The meter falls to its floor the
    moment audio stops being kept, and to zero when capture ends
    (`stopCapture`, the one call all five exits share).
- **A marker row is its timestamp, and its label when it has one.** It used to
  fall back to the section heading, so every row under a heading reading MOMENTS
  read `12:04  Moments` — rendered, and never looked at. `label` stays nil until
  XIA-433 gives markers a meaning to say.

### Pause and resume (XIA-447)

A **fourth capsule** — timer, Mark, Pause, Stop. Pause stops capturing and
keeps the session; Resume continues into the **same** `recording.caf`. **Stop
stays terminal: there is no resume after Stop, ever.**

XIA-422 rejected pause after finding that people reaching for it wanted "this
bit matters", and shipped Mark. That found one real need and wrongly concluded
the other did not exist: Mark is an *annotation* and never stops capture, pause
is a *capture control* and says nothing about importance, and no reading of Mark
serves "I want to use the restroom for two minutes and then hit continue". The
2026-08-11 ruling against a fourth capsule does not carry either — that was
about **Moments**, a browsing affordance on a surface meant for recording.

**A pause lasts forever** (owner, 2026-08-12). No auto-stop, no timeout, no
"still there?". Nota never ends a session on its own.

- **`elapsed` is audio time, not wall clock.** Pause two minutes inside a
  twenty-minute meeting and the recording is eighteen minutes, because the CAF
  is a concatenation of the audio that was *kept* with the paused spans simply
  absent — not a gap of silence, not a second file. Every consumer names an
  offset into that file (a marker's `atSeconds`, a segment's `endTime`, the
  gutter timestamps, `durationMinutes`), so a wall-clock elapsed would put all
  of them two minutes past the audio they name, silently, and worse the longer
  the pause. The fix is at the **producer**: `SessionClock`
  (`macos/Nota/Dictation/SessionPause.swift`) accrues `pausedTotal` and the
  session's ticker publishes `clock.elapsed(now:)`, so not one of the ten
  consumers had to learn that pause exists.
- **One predicate stops the audio, and it stops both destinations.**
  `LiveMeetingSession.capturesAudio(_:)` gates the socket send *and* the file
  write, which is what makes audio continuity a fact about the file rather than
  a hope. It is deliberately separate from `meterFollowsMicrophone`: one is
  about bytes, the other about what may be claimed on screen.
- **Pause drains before it flips the state, and resume discards before it flips
  back.** `handlePCMBuffer`'s guard runs on the main actor at *drain* time, so
  whatever is queued at the press is audio captured while the microphone was
  live — the last word before it. Judging it against `.paused` is the
  `PendingPCMBuffers` defect (XIA-430's "a session's last words") arriving at a
  boundary that happens many times a session instead of once. Hence
  `MicCapture.flushPending()`, called *before* `state = .paused`, exactly as
  `stop()` drains before clearing `isCapturing`.

  Two things that shipped wrong in the first cut and are the reason this is
  written down. **A drain is worth nothing if the buffer callback hops**: the
  session handed each buffer to `Task { @MainActor in … }`, which never runs
  inline, so every drained buffer was judged against the state as it stood
  *after* `pause()` returned and the whole flush was inert. The callback is now
  synchronous under `MainActor.assumeIsolated` (`installCaptureHandler`), which
  is sound because every route into `drainPending` is already the main thread.
  And **the resume direction was not free either**: a buffer converted during
  the pause is drained by a *later* main-thread hop, so one landing just after
  Resume was written into the file and sent to the socket — audio from a span
  the owner was told is absent, which is the worse direction of the two because
  a pause is often taken for privacy. `MicCapture.discardPending()` runs before
  `state = .recording`. `testAPauseKeepsThePrePressTailAndAResumeDropsThePausedSpan`
  drives both across a real `pause()`/`resume()`; its predecessor asserted on a
  hand-built queue and stayed green through both defects.
- **The tap stays installed, and nothing may say the microphone is closed.**
  `stopCapture()` nils `onPCMBuffer` and only `start()` reinstalls it, and
  `MicCapture.start()` re-negotiates the device format and can throw — a resume
  that fails with a `MicCaptureError` is a new failure class on a session that
  is already recording. So pause is `.stopping`'s discipline (tap installed,
  buffers dropped by the state guard) without the teardown. The cost is real
  and is named rather than glossed: **macOS keeps its own microphone indicator
  lit for the whole pause.** Nothing Nota keeps, sends or writes comes from it,
  and the file proves that; but no comment, copy string or doc may claim the
  *device* is closed.
- **The socket: ONE socket for the whole session, kept alive with zeroed
  frames.** Close-and-reopen was rejected on three independent grounds — there
  is no reopen path (`webSocketTask` is assigned only in `start()`, which begins
  by `cancel()`ing the session), a new socket is a new AssemblyAI session whose
  `Termination` covers only the last leg, and a mid-pause close outside the stop
  path runs `failSession`. Sending *nothing* is not available either: an idle
  realtime stream is disconnected and this file's close-code table has no idle
  case, so a pause would silently kill a meeting — and the fix for that
  (capping the pause) is forbidden by "a pause lasts forever".
  What it costs is named rather than hidden: AssemblyAI is streamed, and billed
  for, silence, and its `audio_duration_seconds` becomes wall clock. So
  `SessionDurationChoice` stops trusting the server's figure once a session has
  been paused and seals on the paused-corrected clock instead — otherwise the
  audio-time correction would be undone from the far side. A session that never
  paused is completely unaffected.
- **A paused session must never look stopped.** The owner walks away, comes
  back to a quiet screen, assumes it ended, loses the meeting. The ember going
  out and the clock stopping are both *absences*, and an absence is what a
  stopped session looks like — so the state says its own name, in words, on all
  three surfaces: the cluster (`RecordingPaneCopy.pausedBadge`), the island
  (`MiniIslandPhase.paused`) and the menu bar (the item reads `12:34 · Paused`,
  and its accessibility label says "paused", not "session stopped"). Never a
  colour change alone.
- **The word is drawn INSIDE the Pause capsule, which grows into it** (owner,
  2026-08-12 for the placement, 2026-08-13 for the growth). The control that
  will resume the session is the one saying it is paused, so the state and the
  way out of it are the same object; a badge said the word *near* the row and
  could be read as belonging to any capsule in it.

  Two answers were shipped in order and the second is the one in the tree. The
  badge was an **overlay** — outside the layout entirely, the moment tally's
  mechanism — and it was lifted ≈31pt above the row, where it landed on the
  last lines of the live transcript. Moving the word into the capsule put it in
  the layout, so the first cut kept "nothing moves Stop" by **reserving** the
  wide form in both states (`pauseCapsuleWidth`, `SessionTimerMetrics
  .plateWidth`'s trick for the hour) — and that is exactly the price
  `markerCountWidth` charged and was deleted for: a round glyph adrift in a box
  sized for a word it was not saying, so a row of four capsules drew three
  different-looking gaps.

  So Pause is sized by its content, the growth **is** the state change, and the
  centred row splits it so both neighbours slide rather than one. Stop still
  never moves under the pointer aimed at *it* — the pointer that widened the
  row is on Pause. The tally's rule is untouched and is why it is still an
  overlay: a moment count may move nothing.
  `testOnlyThePauseCapsuleGrowsWhenTheSessionPauses` asserts the shape of the
  growth (the row widens by exactly what Pause widens by; Mark, Stop and the
  timer are unchanged), and **height** is still fixed —
  `testTheWordPausedNeverMovesTheClusterVertically`, because
  `transcriptBottomReserve` is composed from `capsuleHeight` and a taller
  paused row would slide under the glass every time the owner stepped away.

  It is the surface's **first** transition, so Reduce Motion reaches this row
  for the first time: `RecordingMotion.pauseAnimation` returns nil there and
  the two widths are taken as a cut. That is the ring's answer, not the
  meter's, and the asymmetry holds — nothing is lost to a cut, since the word
  is on screen either way and the state is also on the island and the menu bar.

  The curve is the **owner's, picked off the running candidates** (2026-08-13).
  The first cut shipped `spring(0.32, 0.82)` and read "too fast and rigid",
  which is what a tightly damped spring is — it arrives and stops dead, with no
  settle for the eye to follow. Four springs were rendered side by side on the
  real cluster geometry, each solved as a damped harmonic and sampled into a
  CSS `linear()` easing so the page's settle *was* the app's, and `0.70 / 0.62`
  was chosen: the longest open of the four, with visible give. Half of the
  rigidity was not the box at all but the **content** — a word arriving at full
  strength the instant the press landed, inside a capsule that was still
  opening — so the `Text` carries `.transition(.opacity)` on its own, shorter
  curve (`RecordingMotion.pauseTitleAnimation`).
- **`showsRecordingPane` and `drawsMarkerRules` are no longer the same
  property.** The pane stays up while paused (removing it *is* the "looks
  stopped" failure); the ember rules in the transcript margin go, because
  nothing is being captured and the ember means it is. They come back at Resume.
- **Mark is refused while paused, on every surface.**
  `NotaModel.markCurrentMoment` gates on the open microphone, so the capsule is
  disabled (`SessionClusterAction.isEnabled`, back as a per-action question for
  the first time since XIA-445) and the island and menu bar drop the row
  entirely rather than showing a control that does nothing. Pause and Stop stay
  live in both states — an owner may not have to resume in order to end.
- **The status contract: `paused` is a FLAG on `recording`, never a status.**
  To every consumer a paused session *is* recording — it owns a record and holds
  a file open — so the machine is untouched: `isInFlight`, `canAdvance`,
  `interruptedResolution` and the launch sweep all move not at all, and an
  interrupted paused record still resolves to `failed:recording` + `interrupted`
  and reads **"Interrupted"**, which is what happened to it. A new status would
  have been *unsafe* rather than merely expensive: `normalizeHistoryStatus`
  resolves an unrecognized value by what the record HAS, so an older build (or
  the shipped `dist/index.js` the app shells out to) would read `"paused"` as
  `transcribed` — a **rest** state the sweep never revisits — and a paused
  session whose process died would become a finished transcript with no
  transcript in it. Written by `LiveSessionPersistence.recordPaused` through
  `mutateRecord`; declared as `HistoryRecord.paused` in TS so its survival
  across every `{ ...record }` write path is a contract
  (`tests/pipeline/history-paused.test.ts`), the deal `pinned` and `markers`
  already have. Both `describeHistoryStatus(status, {paused})` and
  `HistoryStatus.presentation(interrupted:paused:)` say "Paused", and only for
  `recording`. Each has a **production caller**: `historyStatusLabel` on the CLI
  side, `NotaModel.pauseLiveSession` on the app's, which moves the window's own
  status line — a contract function with no caller in the app is a contract
  only one side keeps.
- **A record that has left `recording` is not paused.** The flag is written at
  press time and only Resume clears it, so a session stopped *from* a pause
  sealed as `{"status": "done", …, "paused": true}` — forever, on the surface
  `nota history show` calls scriptable. It was masked only because both display
  functions gate the word on `recording`, which is a record that is wrong while
  its display happens to hide it: exactly the shape the flag-not-a-status design
  was chosen to avoid. `LiveSessionPersistence.updateStatus` clears it whenever
  the new status is not `recording`, because that one function is the door the
  seal, `settleAsFailed` and the launch sweep all go through.
- **A finalized turn that lands during a pause is kept, on both engines.** The
  Apple analyzer finalizes asynchronously — audio fed at t−0.5s resolves at
  t+0.3s — so the sentence spoken just before the press arrives after it.
  `handleAppleHypothesis` was gated on `.recording` alone and dropped it, and
  Apple's finalized results are deltas, so it was gone from the sealed
  transcript and the summary for good; the WS path's `.turn` handler has never
  had a state guard, so the two engines disagreed about one boundary. Both keep
  it now, stamped with the pinned `elapsed`, which is the right second of the
  audio. The mirror of that: an **empty** end-of-turn is dropped, because a
  pause streams silence and silence is exactly what closes a turn — otherwise
  every pause added a blank line to the transcript and the `.md`.
- **The keep-alive is cancelled on every way out**, including the two the owner
  cannot reach (a mid-pause receive error, and a server-initiated
  `Termination`). It sends through `pauseKeepAliveSink`, a seam that exists
  because `URLSessionWebSocketTask.send` is unobservable and this is the one
  part of pause that spends the owner's money.
- **The badge is drawn in space no line was going to use.** An overlay is
  outside the layout, which is what keeps it from moving Stop — and also outside
  the reserve, so lifted ≈31pt above a 16pt gap it landed on the last lines of
  the live transcript. `clusterTranscriptGap` is now the larger of the two, and
  `transcriptBottomReserve` inherits it. Unconditional, not "wider while
  paused": a reserve that changed at the press would reflow the transcript under
  the owner at the moment the surface is promising to hold still.

### The mini-recorder island and the menu bar (XIA-434)

Nota's **third floating panel** (`macos/Nota/UI/MiniRecorderPanel.swift`,
`MiniRecorderIsland.swift`, `MiniRecorderController.swift`,
`MenuBarSession.swift`). One ~320×44 capsule — ember dot, compact
`SessionMeter`, `SessionTimer`, Mark, Pause, Stop — up **only while a session
runs and Nota is not frontmost**. Bringing Nota forward dismisses it: the
window's own cluster says the same thing, and two live indicators for one
microphone is the mistake `isReviewing` already taught us.

**It carries no transcript, ever**, and that is a fact about the *type* rather
than a discipline: a `MiniIslandPhase` holds only derived strings — never a
transcript, never a segment — so there is nothing for a future edit to render.

**`level = .statusBar` is assigned AFTER `isFloatingPanel`**, and this panel is
the reason the trap matters. `isFloatingPanel = true` silently rewrites `level`
to `.floating`, which sits *below* fullscreen apps. The HUD merely looks wrong
when that happens; this surface exists to float over a fullscreen video call, so
the same mistake makes it useless. The rest of the floating-panel inheritance is
unchanged and non-negotiable: an AppKit `NSGlassEffectView` plate (SwiftUI glass
in a transparent panel renders flat), `appearance = .darkAqua` on the panel
itself, a **verified** `orderFrontRegardless` with one recreate then a visible
failure, `.nonactivatingPanel` with nothing calling `NSApp.activate`, and **its
own** `IslandPositionStore` — the HUD pins a bottom-center and the review card a
top-left, so one shared point would mean dragging either surface moved the other
through an anchor that means nothing on the far side.

**A failure report may not feed the thing that reports it.** `reportIslandUnavailable`
writes `NotaModel.status`, which is `@Published`, and the controller subscribes
to `model.objectWillChange` and calls `refresh()` — so a failed `show` wrote a
status, which republished, which refreshed, which failed to show again, **forever,
allocating two `NSPanel`s per iteration**. The attempt is latched once per
session (cleared when the phase goes nil) and the setter guards an unchanged
notice. `testAnIslandThatCannotBeShownIsReportedOnceAndNotBuiltAgain` drives 25
refreshes and asserts exactly one attempt. This is the XIA-432 trap in a new
coat: the *rate* of a publisher and the *breadth* of its observers multiply.

Four more defects found by review, each a lie the surface would have told:
**Discard announced "Transcribing…"** (the controller read
`isLiveSessionHandedOff`, which `discardLiveSession` also sets — hence
`isLiveHandoffProcessing`, set only in `performStopLiveSession`); **the marker
confirmation congratulated a write that failed** (it now reads "· not saved",
fed from `markersUnsaved`); **Retry was both a dead button and a data-loss
path** — `LiveSessionOwner.start` settles the leftover record and seals nothing,
so Try Again alone discarded the transcript the window's Save Transcript would
have kept, and `.failure` therefore offers `[.show, .retry]`; and **Show did
nothing with the main window closed**, because the subscriber lived inside the
`WindowGroup`'s content and did not exist when there was no window.

The menu bar carries the ember dot and the elapsed time **in the bar itself**,
resolved through `CraftTokens.ember(colorScheme)` rather than the island's
pinned dark value — the island's panel is `.darkAqua`, the menu bar is not.

### What Stop hands over (XIA-429)

Stop routes to the **sealed record's document**, and a **receipt** rises in the
capsule cluster's exact footprint holding the record's facts. This replaces
XIA-429's original answer wholesale: all six of its sub-decisions placed things
"in the rail" — the 288pt trailing session column that XIA-432 → XIA-444 →
XIA-445 deleted — and its load-bearing argument ("the column does not leave, it
changes subject") had no column left to make it about.

**One `RecordFacts`, two renderings.** `RecordFacts.items` is the single ordered
list (duration, kind, speakers, moments, audio, cost) with the single formatter;
the receipt draws it and `RecordFactStripView` draws it, and `stripText` is
defined *as* those items joined. Neither view owns a field list or a formatter,
which is the whole reason this option was chosen — the moment and the document
cannot drift.
`testTheReceiptAndTheStripDrawTheSameFactsInTheSameOrder` asserts identity, not
similarity. Duration goes through `LiveMeetingFormat.duration`, the one clock.

**`durationSeconds` had to be added to the record.** It stored only
`durationMinutes`, rounded **up**, so a receipt rebuilt from the record would
have re-rendered an `18:42` clock as `19:00` — the one number on screen that did
not change. `sealTranscript` writes both; the legacy fallback is
`durationMinutes × 60`.

**The morph in the brief was impossible, and the dead code was deleted rather
than left looking implemented.** The specification asked for the timer capsule
to survive the press and animate its width into the receipt, so "18:42" would be
one continuous glyph run. XIA-435 unmounts the cluster *on the press*, so there
is no capsule to morph. What is left is real: `factDelay` / `factDuration`
handed to `.animation(_:value:)`, and Reduce Motion collapsing to one opacity
swap. `controlOpacity`, `controlScale`, `meterWidthFraction` and `widthProgress`
are gone.

**The receipt is geometry composed from the cluster's, never typed.**
`factRowHeight == capsuleHeight`; `statusRowHeight` is measured from the caption
face and taken **out of** `clusterBottomInset` rather than added to it, so the
fact row lands on the pixels the capsules occupied and
`documentBottomReserve == transcriptBottomReserve` exactly. All three equalities
are asserted. The reserve comes off the **scroll view's own frame**, which is
the XIA-445 lesson. The cost slot reserves the field's **widest** spelling
whether or not it has landed — "final width" cannot mean the landed width, since
that is either `$0.0031` or "included w/ subscription", and reserving the narrow
one still reflows.

**The routing decision lives in exactly one place**, because the owner may
reverse it after living with it: `StopLanding.routesToDocument` in
`macos/Nota/App/BackgroundProcessing.swift`, beside `LivePhaseGate`. Setting it
`false` restores XIA-435's "Stop goes home" and nothing else changes. Both
seal-failure branches `return` above its single call site, so **a failed seal
falls back to `.home` by control flow** rather than by a condition a later edit
could get wrong; discard never reaches the path at all.

**Markers draw as pips in the finished document's gutter** — the 48pt gutter
`HoverTimestampTextView` already reserves. The mapping rule is deliberately
*not* the live surface's: the exported `.md` prints segment **starts**, so a
marker belongs to the last line that had already started. The strip's
"N moments" is a button that walks the pips and wraps, which is the one thing a
pip alone cannot do. No timeline, no list, no popover.

**Kind relabeling is `RecordKindMenuItems`, a view builder and not a second
`ViewModifier`** — two `.contextMenu` modifiers on one view do not merge, the
later **replaces** the earlier, so a separate modifier would have silently
removed Delete audio and Delete record from every drawer row. It writes `kind`
and `summaryOutdated` in one merge-preserving atomic write and **never**
re-summarizes: spending a model call on a mis-click is the failure mode that
ruled out the alternative.

## Record Lifecycle

A history record is created at **sample zero**, not built at the end (XIA-430).
`LiveSessionPersistence.beginRecording` writes `~/.nota/history/<id>.json` with
`status: recording` and makes `<id>.assets/` **before the microphone opens**;
the session records straight into `<id>.assets/recording.caf`, so there is no
move-the-audio step after Stop and nothing to lose if the process never reaches
the end. `sealTranscript` then fills that same record in — same id, same file.

The status is one persisted string, and its vocabulary is the **contract**
between `src/pipeline/history-status.ts` and `macos/Nota/App/HistoryStatus.swift`
— same raw strings, same legacy mapping, same legal transitions, so
`nota history show <id>` reports what the app is displaying:

```
recording → transcribing → transcribed → summarizing → done
                ↓              ↓             ↓
                       failed:<stage>
```

- **`transcribed` is a rest state, not a synonym for done.** It is where a
  transcript-only live meeting comes to rest, and `nota history summarize`
  refuses a `done` record without `--force` — calling a never-summarized
  transcript finished would put every live meeting behind that flag.
- **A record fails only in the stage it is in.** `canAdvance` refuses anything
  else, and `updateStatus` refuses to write an illegal move rather than
  recording a session nobody ran. `transcribed` fails as the summary it was
  waiting for.
- **Legacy records load, and never as live.** `"completed"` → `done`,
  `"transcribed"` keeps its name, and an absent/unknown value resolves by what
  the record HAS (a summary → `done`, none → `transcribed`). Resolving a legacy
  record into a live stage would get it swept up as "Interrupted" at the next
  launch, on every machine, forever. Tolerant per field, like
  `DictationSettings.init(from:)` and `sanitizeCatalog`.
- **Interrupted recovery runs once at launch**, before the first
  `refreshHistory()`: nothing of ours is running, so anything still claiming a
  live stage belongs to a process that went away. Those become
  `failed(stage:)` + `interrupted: true`, which presents as **"Interrupted"**
  rather than naming a stage that never got the chance to fail on its own.
- **`audioPath` is relative to the record's own assets folder** (normally just
  `recording.caf`), so the whole store can be relocated without rewriting a
  single record (XIA-428). `sourcePath` stays absolute for the consumers that
  read it, and is the *fallback* for records that predate `audioPath` — never
  the authority when both exist. `LiveSessionPersistence.resolvedAudioURL`
  (Swift) and `recordAudioPath` (TS) are the two halves of that rule;
  `HistoryRecordInfo.find` resolves through the Swift one, so a record whose
  store moved still names audio that is really there — but it does **not
  require an answer**: both names for the audio are cleared by `delete-audio`,
  and a record without audio is still a record (XIA-436). Nothing in the TS CLI
  reads a record's audio yet — every verb takes its input path from argv — so
  `recordAudioPath` is exercised by tests alone, deliberately.
- **`audioBytes` is corrected at every exit, never only at the seal.**
  `beginRecording` writes 0, which is true at sample zero and a lie from the
  first buffer on; `sealTranscript` stamps the final size, and `settleAsFailed`
  and the launch sweep stamp whatever was captured before things went wrong. An
  interrupted record's recording is playable, so the record may not describe it
  as empty. The field is always present, so no consumer has to tell "zero" from
  "never written".
- **Nothing deletes audio.** `deleteAudioFile()` and every call to it are gone;
  `LiveMeetingSession.closeAudioFile()` drops the handle and the URL and does
  **not** touch the file — `audioFile = nil; audioURL = nil` is the whole body,
  and there is deliberately no delete counterpart anywhere in that type. A
  failed transcription leaves the audio; a failed summary leaves the audio
  **and** the transcript. Audio is the one artifact that cannot be regenerated,
  and the failures are exactly when it is wanted. Deletion is an explicit user
  verb, not a failure path.

### The session lifecycle around that record

The record is the durable half; these are the rules the *call sites* owe it.
They live in `LiveSessionOwner` (`macos/Nota/App/LiveSessionLifecycle.swift`)
rather than in `NotaModel`, because `NotaModel.init` sweeps the real `~/.nota`
and runs preflight — a test cannot build one, and every defect below was a call
site, not the machine.

- **A Start press is accepted the moment it is seen, and the pane says so.**
  `LiveMeetingSession.start` stays `.idle` across the mic-permission prompt and
  the whole realtime open + `Begin` round trip, and a guard that asked only "is
  it recording?" admitted a second press in that window. The second press wrote
  a second record, took ownership, and cancelled the first task — whose cleanup
  then cleared the *new* owner, so Stop found no record, sealed nothing, and the
  whole meeting's transcript was lost while the record still said `recording`.
  `isStarting` closes it in the model; `LiveMeetingControls.starting` closes it
  on screen (the Start button is withdrawn, the header says "Starting…", and
  ContentView enters the live phase from the press rather than from
  `.recording`).
- **A task may only clean up after itself.** `release`/`settle` take the record
  the task was started for and do nothing unless it is still the owned one. An
  unconditional `activeRecord = nil` in a cancelled task is what disowned a
  live session.
- **Every exit reaches a terminal status, and each has a route.** Clean stop
  seals; a mid-session failure keeps the pane with **Save Transcript** (a failed
  session is stoppable on purpose — `stop()` accepts `.failed` so the transcript
  it heard can still be sealed), Try Again and Discard, and each of those
  settles the record; a **server-initiated** end (`Termination`, or a clean
  close) leaves no affordance at all, so `observeLiveSessionState` runs the stop
  path itself; a process that goes away is the launch sweep's job. `.failed` is
  deliberately not auto-settled: the banner is a pending decision, not a strand.
- **A failure is written in the stage the record is IN.** `settleAsFailed` reads
  the stage off the record instead of trusting the call site. `canAdvance`
  refuses any other stage, `updateStatus` then writes *nothing*, and a discarded
  false is a record claiming a live stage forever — which is exactly what the
  stop path's `failed(stage: .transcribing)` on a `recording` record did.
- **A write that did not land is never reported as success.** `mutateRecord` and
  `updateStatus` are not `@discardableResult`; `sealTranscript` throws
  `recordUnwritable` rather than returning a `SavedSession` for content that is
  not on disk. And it writes the **content first and the status last**: the two
  are separate atomic writes, and a crash between them must leave `transcribing`
  (which the sweep resolves) rather than `transcribed` (a rest state the sweep
  will never revisit, with no transcript and no `outputPath` in it).
- **The CLI's write path honors the machine too.** `canCompleteWithSummary`
  gates every verb that lands a summary (`setRecordSummary`,
  `completeHistoryRecord`, `applyEnrichmentToRecord`), so `nota history
  summarize` can no longer write `done` over a record that never reached a
  transcript. It is expressed through `canAdvance` rather than beside it, and it
  still admits the three real retries: `summarizing`, `done` (`--force`), and
  `failed:summarizing`.
- **`nota history show` and `nota history list` print the state the app
  displays.** `historyStatusLabel` wraps `describeHistoryStatus`; `show` puts it
  on **stderr** (stdout stays the record's JSON) and `list` carries it in a
  trailing `State` column beside the raw `status` scripts match on.

## Key Design Decisions

- Nota is the primary name; MeetingSum references exist only for backward compatibility.
- The record comes before the audio, and the audio is never taken away
  (XIA-430). Building the record at the end meant every failure before the end
  — a crash, a dead socket, a process killed mid-sentence — left the recording
  in a temp file with nothing pointing at it, and the cancel/failure paths then
  deleted it outright. Now `beginRecording` writes the record and its assets
  folder first, the session records into that folder, and every later step
  edits the record in place. What falls out is worth stating: a record can
  exist with nothing in it (so the launch sweep has to resolve interrupted
  ones), the status has to be a typed machine rather than an ad-hoc string (so
  a record cannot claim to have skipped a stage), and no failure path may
  remove a file. See Record Lifecycle.
- A durable record is only worth what its **call sites** honor, and all three
  of that inversion's real defects were call sites rather than the machine
  (XIA-430, second pass). A live session's record ownership therefore lives in
  one testable type (`LiveSessionOwner`): one record at a time with the press
  accepted the instant it is seen (a second press during the invisible,
  seconds-long start window used to disown the session that was recording the
  meeting), cleanup that may only clear the record the task itself started, and
  a settle on every way out — including the two the user cannot reach, a
  server-initiated end and a process that went away. Writes are checked and the
  content is written before the status claims it: a `SavedSession` returned for
  a write that did not land is a record saying Transcribed with no transcript
  in it, and a status flipped first turns a crash into a record the launch
  sweep will never look at again. See Record Lifecycle → the session lifecycle.
- Model registry (`src/registry.ts`) is the single source of truth: model id → task, provider, required API key env, base URL. Transcription models are statically curated; summary models are sourced dynamically from the auto-refreshed catalog (`src/catalog.ts` + `~/.nota/models-catalog.json`) with a baked in-repo fallback. Only the API keys the resolved models actually need are required.
- Summary model ids are auto-admitted weekly: mainline chat models (gpt-5.x, gemini flash/pro, deepseek v4+) matching allowlist predicates. Run `nota models list` for the current set.
- Summary default is key-aware: `deepseek-v4-flash` > `gpt-5.4-mini` > `gemini-3.6-flash` based on which API key is set. A hint is printed when DeepSeek is skipped despite being the cheapest option. CLI engines never join that chain (ADR 0003).
- A summary model that is not an endpoint is a first-class registry entry, not a special case: `claude-code/*` and `codex/*` carry `execution: "cli"`, and every decision about them is made on that kind — `requiresApiKey` (so a run is not refused for a key it was never going to use), `cliEngineFor` (which returns a spec or `undefined`, and is the argument the summary path branches on), `httpModelsForTask` (so no subprocess can reach dictation polish). The id is never pattern-matched. `makeSummaryCall` puts the HTTP client and the subprocess behind one shape, which is what lets the sectioned >100k-token flow route every section and the roll-up through a CLI engine without a second copy of the loop. See CLI Engines.
- A CLI engine's isolation from the owner's own agent configuration is a claim about *those* CLIs, so it is measured rather than assumed. A scratch cwd was assumed sufficient and was not: `claude -p` and `codex exec` both read a user-level guide out of the home directory whatever the cwd, and a meeting summary was being written under this machine's `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. The mechanism differs per engine because the CLIs differ — `--safe-mode` for one, a private `CODEX_HOME` for the other, since codex has no flag that reaches its AGENTS.md (`--ignore-user-config` and `project_doc_max_bytes=0` were both measured and both insufficient). Whichever mechanism is chosen must leave **auth** alone: `claude --bare` does the isolation and forces auth onto `ANTHROPIC_API_KEY`, which would move a run billed "included w/ subscription" onto a metered account. See CLI Engines.
- Pricing for summary models comes from the catalog via `computeSummaryCost` (tier-aware, ×1e-6 unit assertion). Pricing for transcription models remains a static table in `src/pricing.ts`.
- AssemblyAI as default provider: transcription + diarization in one API call ($0.15/hr)
- Whisper retained as fallback via `--provider whisper`
- `.qta` files auto-converted to `.m4a` via ffmpeg before AssemblyAI upload
- Speaker identity is a pure-Node ONNX d-vector pipeline: `onnxruntime-node` runs the WeSpeaker ResNet34-LM model over JavaScript-computed Kaldi fbank features, and stored L2-normalized embeddings are matched by cosine similarity. It needs no Python, hosted API, or identity-specific API key. The pinned model is downloaded on first use, checksum-verified, and cached at `~/.nota/models/wespeaker_en_voxceleb_resnet34_LM.onnx`; if the model or native runtime cannot load, identity no-ops with a clear message while the rest of the pipeline continues. The first-run download announces itself with one stderr line (identify-by-default means it happens mid-run).
- Voice audio is captured **during** the pipeline run (the source audio is often a temp file deleted afterward): a per-speaker PCM clip is saved under `~/.nota/history/<id>.assets/<label>.pcm` on **every** diarized run with history enabled — recognition or not — and naming a speaker later enrolls an ONNX embedding from that stored clip, so enrollment works without the original audio. Speaker store schema v4 holds numeric d-vector arrays under `~/.nota/speakers.json`; incompatible v3 Eagle voiceprints are dropped with a warning and must be re-enrolled.
- Speaker identification is **auto by default** (decision 1 of the speaker-workflow map, XIA-406): recognition runs on every diarized transcription whenever the store has ≥1 enrolled voiceprint, in both the CLI and the macOS app. `--no-identify` (and the app's identify toggle) opts out; `--identify` forces it on, which is the path for first-time enrollment of unknown speakers (interactive TTY; freshly-typed names are enrolled inline from the captured clip). A `.qta` input is pre-converted to a durable 16 kHz wav whenever the run will read the audio after transcription (identification or clip capture), because the source temp file may vanish when the share sheet closes.
- Tentative-band matches ([0.50, 0.65) cosine) are never silently dropped: they persist on the history record as `suggestions` (`{label, suggestedName, score, voiceprintId, state, decidedAt?}`) and surface on the macOS speaker chip as "Speaker 2 → Kenny Kim? 0.62" with accept/dismiss. Accept = rename propagation (segments, clip, output `.md`) + enroll the record's clip as a new voiceprint; dismiss = clear on this record only. `nota history suggestions --recompute <id>` backfills an old record from its stored clips (no migration sweep). Confident matches (≥ 0.65) auto-label as before; threshold bands are fixed (0.65 / 0.50, measured in `docs/research/voiceprint-cosine-bands.md`) — never per-speaker, never learned.
- Enrollment hygiene: a new voiceprint that disagrees strongly with the person's existing prints (best same-name cosine < 0.5) warns on stderr naming the score and is marked `lowAgreement` on the print — never refused, never silent. `nota speakers doctor` lists flagged prints and same-name pairs below 0.30 for delete/reassign. A rename/accept landing on a completed record sets `summaryOutdated`, which surfaces a one-click "Regenerate summary" affordance in the app until used or dismissed; a fresh summary clears it.
- Long transcripts (>100k tokens) are summarized in sections then rolled up
- Output saved as markdown file next to input by default
- Byte-level (SHA-256) duplicate detection: when history is enabled (the default), Nota hashes the raw audio once in `runPipeline` and, if an identical file already has a *completed* history record whose output `.md` still exists, reuses that summary and skips transcription. `--force` overrides; a hash failure warns but still transcribes. This gates the common case (same file shared twice) cheaply before any paid call; it is a byte hash, not an acoustic fingerprint, so a re-encoded copy of the same recording is not detected. Legacy records (pre-feature) have no `contentHash` and never match. Example: `nota recording.m4a --force` reprocesses a file already in history.
- The custom dictionary (`~/.nota/dictionary.json`, schema v1) is one file with two writers — `src/utils/dictionary.ts` and `macos/Nota/Dictation/DictionaryStore.swift`. Both write atomically (temp file + rename) and both *read* a missing or corrupt file as an empty dictionary with a warning, never a hard failure: dictation must not be blocked by a bad dictionary. Decoding is tolerant per entry on both sides (one damaged entry costs only itself; unknown `source` degrades to `manual`, missing optionals default), so a hand-edited typo or a file written by a newer version still loads. Reading-as-empty is safe only for reads: before a *write*, a wholly unparseable file is copied to `dictionary.json.corrupt-<epoch>` and the store starts over, because auto-learn calls `add` unattended and would otherwise replace every unreadable term with the one it just learned. In-process writers (Settings pane, auto-learn) are serialized by a lock in `DictionaryStore`; the CLI is a separate process and stays last-write-wins.
- `DictationSettingsStore` backs onto a private, wiped-at-start UserDefaults
  suite whenever it runs under XCTest (env-var detection, like the
  single-instance guard's bypass). An unhosted test bundle's
  `UserDefaults.standard` reaches the real `com.xiafawu.nota` domain, so the
  store tests' `reset()` used to delete the owner's saved dictation settings on
  every test-gated deploy — experienced as "Nota forgets my settings on every
  redeploy" (2026-07-28: polish model, HUD style). Tests must touch defaults
  only through `DictationSettingsStore.defaults`;
  `testStoreIsIsolatedFromTheRealDomainUnderXCTest` pins the isolation.
- `DictationSettings` decodes field by field (`init(from:)` in
  `DictationTypes.swift`), never through the synthesized `Decodable`. The
  synthesized one ignores property defaults and throws on a missing key, and
  `DictationSettingsStore.load()` turns any throw into factory defaults — so
  every new setting would silently wipe the user's engine, trigger, polish and
  HUD preferences on first launch after an upgrade. Tolerance is per field: a
  payload that is not a keyed container at all still resets, which is what
  should happen to a corrupt one. Add new settings with a default value **and**
  a line in `init(from:)`.
- Dictation delivery is one enum with three values
  (`DictationSettings.deliveryMode`), not independent toggles: streaming and
  review are contradictory answers to "when does this text become the user's
  problem", and a flag pair would let both be on. `.immediate` is the default
  and behaves exactly as the pipeline did before either mode existed — no target
  captured at session start, no segment hypothesis produced, injection in
  `.standard` mode.
- Streaming dictation delivery is opt-in because it is the one part of the
  pipeline that cannot be undone: text appended to a live document while the
  user talks is already in their file. Its guarantees are append-only delivery,
  spoken order regardless of polish completion order, a target fixed at session
  start, and per-sentence fallback to offline text when polish fails.
- Review delivery is the opposite trade: nothing at all reaches the target until
  the owner applies it, which buys the highest-quality dictionary signal the app
  can get (a human correcting the model) at the cost of a keystroke per session.
  It costs no *focus*: the panel is nonactivating, so the app being dictated into
  stays frontmost throughout. Its diffs are learned only on Apply — text the
  owner discarded teaches nothing. See Dictation Delivery.
- **Review mode has exactly one surface** (owner call 2026-08-03). The card is
  opened when the hotkey goes down, not when the session stops, and the HUD
  never appears in that mode — one NSPanel, a recording state and a deciding
  state, with the transition between them being the flag a continuation already
  set. The decision half is byte-for-byte what it was: same `PendingReview.id`,
  same callbacks, same target-pid and epoch rules, same `finishReview` guards.
  Two consequences fall out and both are load-bearing. A card can now exist with
  nothing in it, so every abort path runs `endReviewRecording`, which takes an
  empty card down and leaves one the owner has typed in alone. And an error has
  to be able to land on the card, because the pill's last exception (`.failed`)
  is gone — `state`'s `didSet` mirrors it into the card's status line, and it
  falls back to the pill exactly when there is no card, since `isReviewing` is
  literally "a card exists".
- **One surface means one text box, too** (owner, same day, on seeing it: "I'm
  not sure why we have review dictation and a preview… maybe we could merge
  those 2 things together, into one text box"). The live draft is drawn as a
  dimmed suffix *inside* the review editor, not in a block beneath it, which is
  why that editor is an `NSTextView` (`ReviewEditor`) rather than SwiftUI's
  `TextEditor` — `TextEditor` binds a plain `String` and cannot draw part of its
  content in another colour. Merging the two views did **not** merge the two
  values: `model.text` is the owner's buffer and the only string ever read back
  out, the draft occupies the range past its end, and only that range is
  rewritten per recognizer tick. Two things fall out. The card's height is now
  fixed for its whole life — the block's `setDraftBlockShown` growth is gone,
  and a surface the owner types into no longer resizes under them. And because
  the box is Nota's own text view rather than someone else's field, Nota owns
  what macOS would do to the text in it: smart quotes, substitutions,
  autocorrect and inline prediction are all off, or a silent rewrite between the
  pipeline and Apply would have the owner endorsing a spelling nobody chose.
- **A button the owner cannot press is not feedback** (owner, same day: "when it
  is dictating it still shows those 2 buttons grayed out… make it some other
  button like End or Finish, so I don't have to press the globe key to stop").
  The card's prominent slot is **Finish** while a session records and **Apply**
  when one is not; ⌘↩ and the button both go through
  `DictationReviewModel.primaryAction()`, so "what the primary action means" is
  written down once, the way `apply()` already was. Finish is deliberately not a
  decision — it never reaches `DictationReviewPresenter.finish`, and Discard
  stays refused, because a decision about a batch still being spoken is the one
  thing the recording state exists to prevent. It ends the session through
  `endCaptureAndFinalize()`, the *same* call the trigger key's release makes, and
  tells `HotkeyMonitor.resetToggle()` first: in `.toggle` activation the monitor
  latches "a session is running" from presses it saw, and a session that ended by
  a route it cannot see would cost the owner one dead press.
- **A toolbar item does not need its own glass.** On macOS 26 the toolbar draws
  the Liquid Glass capsule around its items itself, so a `.liquidGlass(…, in:
  .capsule)` *inside* a `ToolbarItem`/`ToolbarItemGroup` stacks two translucent
  capsules and two rims. That is what the "washed-out light capsule with a
  doubled outline" was on the `Checking…` health pill — a main-window control,
  not the dictation HUD, and light because the window it lives in is allowed to
  be. `HealthPillView` and `ToolbarStatusPill` therefore draw their content and
  let the group carry the surface. Outside a toolbar, `.liquidGlass` is still
  the right call.
- A **floating panel is a single-theme surface, and SwiftUI cannot make it one.**
  `.colorScheme`/`.preferredColorScheme` set a SwiftUI *environment* value; they
  do not change an `NSWindow`'s `effectiveAppearance`, which is what every
  AppKit-drawn piece inside a hosting view follows — `ProgressView`, control
  accent resolution, `NSVisualEffectView` materials, a text view's insertion
  point. A panel with no explicit appearance inherits `NSApp.appearance`, which
  Settings → General now pins (`AppearanceSetting.apply`). So the HUD and the
  review card both assign `appearance = NSAppearance(named: .darkAqua)` on the
  NSPanel itself. The review card has carried that line since it shipped; the
  HUD pill did not, and under a Light-pinned app it rendered as a washed light
  capsule with dark-styled content on top of it. Any new floating panel that
  commits to one look owes the same line.
- **A floating panel's Liquid Glass is AppKit's, not SwiftUI's** (2026-08-03).
  `.glassEffect`/`.liquidGlass` inside a transparent `NSPanel` refracts only the
  content inside its own SwiftUI hierarchy — measured, and on a HUD whose
  hierarchy is a mic glyph and a line of text the result is a flat grey blur,
  which is why the dictation surfaces originally pivoted to a hand-drawn dark
  fill instead. `NSGlassEffectView` is a real AppKit view with a
  window-server-side effect and refracts the screen *behind* the panel, which is
  the whole point of glass on something that floats. So both dictation panels put
  one under their hosting view (`GlassBackingView`), and the rules that fall out
  are worth restating for the next floating surface: the plate is laid out at the
  **card** rect (the frame inset by the shadow margin) with the hosting view
  above it at **full** bounds, because the padding that produces that margin lives
  inside the hosted view and is what every pinned fitting-size baseline measures;
  the plate is given the panel's corner radius as a *number*
  (`HUDGlassMetrics.cornerRadius`), since an AppKit view cannot take a `Shape`;
  it is tinted dark, because these panels sit over arbitrary content with white
  text on them and untinted regular glass over a bright background is exactly the
  washed-out surface the flat fill existed to prevent; and it takes no clicks, or
  it would swallow the HUD's drag handle and the review card's text selection.
  What SwiftUI keeps is the padding, the forced dark `colorScheme`, and any
  **semantic** wash — the neutral fill and the hairline go, because the plate has
  its own rim and a second one is the doubled outline the toolbar bullet above
  describes. `appearance = .darkAqua` on the panel is still owed, and now more
  than before: the glass resolves against it.
  **How dark that tint is, is the owner's** (`DictationSettings.hudGlassOpacity`,
  the Glass opacity slider in Dictation → Heads-Up Display; default 0.55, after
  0.35 shipped and read as "a little too see-through"). Only the **alpha** moves
  — `GlassTint` keeps the hue fixed at white 0.06, because a tint that could go
  off neutral would colour a surface whose only job is to let white text be read
  over an arbitrary backdrop — and it is clamped to `GlassTint.range`
  (0.20…0.90) at every boundary a stored number crosses: the setter, the decode,
  `GlassBackingView.tintAlpha`, and both panels' entry points. Neither end of
  that range is a look: below it white text stops surviving a white document,
  above it the refraction stops reading as glass and the panel is the flat fill
  this replaced. It reaches the surfaces through the paths that already carry
  settings — the HUD on `panel.update(…, glassOpacity:)`, which runs on every
  RMS tick, and the review card through `DictationReviewPresenting.glassTintAlpha`,
  which the controller assigns from `applySettings()` so a Settings visit retints
  a card that is already up. The slider itself commits on mouse-up rather than
  per frame: this pane saves and calls `reloadSettings()` on every change, which
  restarts the hotkey event tap, and neither floating surface is on screen while
  Settings is — so a live preview would cost keystrokes for nothing.
- A review card is a **batch**, not a session (changed 2026-07-28 on user
  feedback). Pressing the trigger with one open continues it: the card stays,
  the new session's text is appended to whatever the owner has in the box, and
  one ⌘↩ applies all of it. The card therefore needs a state the pipeline never
  needed before — "a decision is not available yet" — and the review keeps one
  `id` across continuations while bumping a `generation`, so "extended" and
  "superseded" stay distinguishable to the guard that judges a late decision.
  Appending to the *editor* rather than to the pipeline's own accumulation is
  the load-bearing half: the owner's corrections are theirs, and a mode whose
  whole purpose is to capture them may not regenerate over them.
- Nota's synthetic keystrokes must not inherit the owner's fingers. A `CGEvent`
  built from a `CGEventSource` carries that source's modifier state, and
  `.combinedSessionState` includes the physical keyboard — so a keystroke posted
  while ⌘ is held arrives tagged as a command and is dispatched as a shortcut
  rather than inserted, silently, while the controller reports success. Two
  independent defences, and both are needed: `TextInjector` zeroes `flags` on
  the events it builds (our event never claims to be a shortcut), and
  `ModifierClearance.wait()` bounds-waits for the real modifiers to come up
  (the *target's* modifier state comes from the keyboard, not from our event).
  This is what made review-mode ⌘↩ drop a session's text while the Apply button
  worked. Scope it correctly when reading the next report: the missing `flags`
  assignment was in `tryCGEventInject` only, so it hit the `.keyEvents`
  terminals and any target that got there by AX writing having failed. The
  `.paste`-forced bundles (Chrome, Chromium, Edge, Slack, VSCode, Copilot,
  Spotify) were never affected by it — `PasteInjector.synthesizeCommandV` sets
  `.maskCommand` deliberately, because its event *is* a shortcut. The wait runs
  before every injection anyway, since the strategy is chosen inside
  `TextInjector` at delivery time. See Dictation Delivery.
- What a delivery mode asks of the recognizer is a pure decision
  (`DictationSessionPlan.make(mode:engine:)`), separate from what it may do with
  the results. "Show a live rough draft" and "put text in the user's document"
  are independent, and collapsing them into one `wantsStreaming` flag is what
  left review mode on the batch recognizer with a silent pill for a whole
  session. Only the Apple analyzer can supply either; AssemblyAI realtime
  reports whole formatted turns, so a review session on it runs the batch path
  and still captures the target pid Apply needs.
- The dictation HUD pill has exactly **one animation authority**: the panel's
  window frame, animated by `NSAnimationContext` in `DictationHUDPanel.update`.
  SwiftUI used to animate the pill's own layout at the same time
  (`.animation(value: state)`), and two curves driving one geometry is what read
  as jitter. The only SwiftUI animation left is the meter's, inside a
  fixed-height frame — nothing that can change a size. Two ordering traps live
  in the same file: `isFloatingPanel = true` silently rewrites `level` to
  `.floating` (below fullscreen apps), so `.statusBar` must be assigned *after*
  it; and growth is **upward with the bottom edge pinned** — `update` changes
  `frame.size` and never `frame.origin.y` — so the reading line stays on the
  anchor and the room for the growth is reserved *above* the panel at placement
  time. (This bullet used to say the opposite, "a taller pill has to grow
  downward or it walks up into the focused window"; the owner asked for the
  reverse on 2026-08-01, which is what commits `29f36f0`/`9a5075a` implemented
  and what `HUDPanelLayout.pillOriginY`'s reserve exists for.) A drag is the one
  frame change that does not go through the animation authority — it calls
  `setFrameOrigin` directly, so it can never be in flight against the growth
  animation.
- The HUD's three styles (`DictationSettings.hudStyle`) are three shapes for one
  panel, not three HUDs. `.pill` is the default and the shape whose geometry is
  pinned tightest — `HUDPillBaselineTests` asserts its exact height per draft
  line, its constant width, and that no draft outgrows the reserve. That is why
  the bar and prompter carry their own material and meter instead of a shared
  extraction of the pill's. The bar is the one style with no growth animation —
  it is a hard-framed 520×40, and `HUDStyle.animatesGrowth` is what tells the
  panel not to animate a size that cannot change. Both other styles grow upward
  and are therefore *placed* with all of that growth already reserved above them
  (`HUDStyle.reservedCardHeight`), because the clamp that keeps a panel on screen
  would otherwise undo the pinned bottom edge one line at a time. The prompter
  keeps a 6-line cap on top of that (past it the text is clipped bottom-aligned
  rather than laid out taller); the pill's cap is its 8-line
  `draftLineLimit`.
- The HUD is **draggable, and a dragged position wins**. `HUDDragView` claims
  every point of the panel's surface (`hitTest` returns self — the HUD has no
  controls) and moves the window against the mouse-down anchor rather than
  summing per-event deltas, which drifts. The cost, taken deliberately, is that
  the panel no longer sets `ignoresMouseEvents`: clicks on the HUD's own
  rectangle stop passing through to the app underneath. Nothing else changes —
  the panel is `.nonactivatingPanel` and never becomes key, so a click on it
  still cannot raise Nota or move focus off the app being dictated into.
  `HUDPositionStore` persists **one** point for all three styles, and it is the
  pill rect's **bottom-center**: the bottom edge is the one upward growth pins
  (so it survives the HUD getting taller) and the horizontal center is the only
  x that survives a style switch between a 200pt pill and a 600pt prompter.
  Restoring validates rather than trusts (`HUDPanelLayout.validatedPinnedPoint`):
  a point no current screen contains is **dropped**, and the automatic placement
  is the self-heal — clamping it onto whatever display is left would call an
  arbitrary point the owner's choice. A point a screen still holds is clamped so
  the HUD and its reserved growth room stay wholly on screen. While a pinned
  point survives that check `reposition()` returns early: neither a new session
  nor a screen change moves the HUD back under the focused window, and there is
  no reset affordance — the way back to automatic placement is to drag it
  somewhere the screen cannot hold, or to remove the defaults key.
- The automatic placement does not rest on the screen's bottom edge.
  `HUDPanelLayout.restingBottomMargin` (56pt above the 8pt hard floor) is where
  it stops: nearly every window reaches close to the bottom of the visible
  frame, so "hang 12pt under the focused window" collapsed onto the hard floor
  for almost every anchor and the HUD sat in the last few points of the screen,
  over the Dock, reading as half off it. The hard floor still wins on a screen
  too short to honour the margin — on screen beats comfortable.
- A HUD style that draws text may only measure and lay out what it can show.
  The prompter's body is head-trimmed to a bounded window before it is measured
  (`HUDPrompterMetrics.windowed`): the HUD re-renders on every 66 ms RMS tick and
  a session's text has no upper bound, so "lay out the whole session, then clip
  it to six lines" is an unbounded cost on the main actor. The window is wide
  enough that the clamped line count — the only thing the card's height depends
  on — is the one the full text would have produced.
- **A feed that ticks does not belong on an object a window observes**, and
  what a `LazyVStack` defers is only its **direct** children. The two together
  are how the recording pane came to rebuild a whole meeting 45 times a second
  (XIA-432): the microphone level was a `@Published` property of
  `LiveMeetingSession` — observed by `ContentView` and `LiveMeetingView` — and
  the transcript was one `LazyVStack` child, because grouping by a speaker label
  the pipeline never fills produces exactly one block. So the level lives on its
  own `MicLevelFeed` that only the meter observes and is gated to ~15 Hz, the
  transcript is a flat list of rows, and the row model is memoized against the
  transcript rather than recomputed per render. The same trap is already written
  down for the HUD prompter one section up; the general rule is that the *rate*
  of a publisher and the *breadth* of its observers multiply, and neither is
  visible from the line that assigns the value.
- The HUD draft feed is split at the source (`finalizedDraft` + `roughDraft` →
  `HUDDraft`), not merged and re-split downstream: a 120-character tail cannot be
  un-merged, and the prompter needs the finalized and volatile halves at full
  length and drawn at different opacities.
- `orderFrontRegardless()` can silently fail to produce a window (2026-07-27:
  `windowNumber == 0` for a day, only a relaunch fixed it). Every HUD show is
  therefore checked, and `HUDVisibilityMonitor` escalates: recreate the NSPanel
  once, then a fault log plus one user notification per run. A watchdog re-checks
  ~1s after the show that brought the pill onscreen. The monitor knows AppKit
  only through an injected `windowNumberProvider`, so the escalation is tested
  without a WindowServer. The review card runs the same check on the way up
  (`DictationReviewPanel.verifyWindowDevice`, one recreate, then a false return
  the controller turns into a visible failure) — no window Nota shows may be
  assumed onto the screen.
- A session's last words are lost at the two places the tail is still in
  flight when the owner lets go, and both are now closed (2026-08-03; the
  earlier `aff047d` / `2420834` fixes were the AssemblyAI half of the same
  symptom). **The recognizer**: the batch Apple path — the default, `.immediate`
  on `.apple` — infers finality from the teardown flag `didFinalize`, so the
  first result to arrive after the release is labelled final whatever it
  contains, and it used to seal `finish()`. That result is a preview of audio
  the analyzer has not finished resolving, so releasing close behind the last
  word ate it. A result now resolves nothing (`BatchTranscript`, the pure
  decision core); only the end of the results stream — i.e.
  `finalizeAndFinishThroughEndOfInput()` having flushed everything — or the
  existing 5s watchdog does, and the watchdog returns the best text so far, not
  nothing. The interpretation of a result is deliberately unchanged (the latest
  non-empty one *is* the transcript); only the moment of resolution moved.
  **The microphone**: `MicCapture` converts on the audio thread and delivers on
  the main thread, and the buffers crossing that hop when `stop()` ran were
  dropped by an `isCapturing` check that had already flipped — silently
  discarding the last audio of every session, for as long as the main thread
  had been busy. They are queued in `PendingPCMBuffers` and `stop()` drains
  them synchronously, before the analyzer is told the input ended. Text delayed
  beats text lost; text captured and then thrown away is neither.
- ESM-only project (`"type": "module"` in package.json)

## External Requirements

- `ffmpeg` and `ffprobe` must be installed and in PATH
- Node.js 18+
- Environment variable: `OPENAI_API_KEY` — required only when a resolved model is an OpenAI model (any `gpt-*`/`whisper-1` transcription or summary model). Not needed for, e.g., AssemblyAI transcription + Gemini summary.
- Environment variable: `ASSEMBLYAI_API_KEY` — required when the resolved transcription model is an AssemblyAI model (`universal`/`whisper-1`/`gpt-4o-transcribe`/`gpt-4o-mini-transcribe` — the default is `universal`)
- Environment variable: `GEMINI_API_KEY` — required when the resolved summary model is a Gemini model
- Environment variable: `DEEPSEEK_API_KEY` — required when the resolved summary model is a DeepSeek model (`deepseek-v4-flash`/`deepseek-v4-pro`). Note: `deepseek-v4-flash` is the cheapest default and is selected first when `DEEPSEEK_API_KEY` is set.
- Environment variable: `OPENROUTER_API_KEY` — required when the resolved summary model is an `openrouter/…` model. No OpenRouter model is ever chosen by default (it is absent from the key-aware chain), so this key is needed only after an explicit `-m` or `nota settings set summary.model`. `nota config` shows whether it resolves.
- `claude` or `codex` on PATH, logged in — required only when the resolved summary model is a `claude-code/…` or `codex/…` id. No API key applies and none is passed; the CLI uses its own login. Never chosen by default, so this is needed only after an explicit `-m` or `nota settings set summary.model`. `nota config` shows which binaries resolve and at what version.
- Speaker identity (auto-run, `--identify`, and `nota enroll`) needs no API key or Python. It uses `onnxruntime-node` and auto-downloads its checksum-pinned ONNX model on first use.
- For `--provider whisper` with diarization only: Python 3.8+ with `pyannote.audio`, plus `HUGGINGFACE_TOKEN` (pyannote is not used for speaker identity)

### API-key config file

Instead of exporting env vars, keys may be placed in `~/.nota/config` as a
dotenv-style file (`KEY=VALUE`, one per line; `chmod 600`). Every `KEY=VALUE`
line is loaded generically (no allowlist), so future providers like
`GEMINI_API_KEY` work with zero code change. Real environment variables always
override file values (the file only fills unset keys). Set `NOTA_ENV_FILE` to
point at a different path. Run `nota config` to see which keys resolve and from
where (values are masked; secrets are never printed). The same command ends with
a CLI-engine block — binary, path and version, or "not found on PATH" — because
a diagnostics command that listed only keys would answer "everything resolves"
on a machine where `claude-code/sonnet` cannot run at all.
