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
  - `speakers.ts` — loads the persistent v4 voiceprint store and matches diarized labels to enrolled speakers
  - `write.ts` — generates markdown output file; header carries **Captured** (recording time from container metadata, fs-birthtime fallback) and **Transcribed** (processing time) dates
- **src/utils/** — Shared helpers: ffmpeg wrapper (`ffmpeg.ts`), PCM decoding/slicing (`pcm.ts`), ONNX model download/cache (`model.ts`), token estimation (`tokens.ts`), capture-date resolution (`capture-date.ts`).

## CLI Flags

- `--provider <name>` — back-compat alias that seeds the transcription model: `assemblyai` (default → `universal`) or `whisper` (→ `whisper-1`). Yields to an explicit `--transcribe-model` or a `transcription.model` setting.
- `--transcribe-model <id>` — transcription model id from the registry (overrides settings.json and `--provider`)
- `--num-speakers <n>` — expected speaker count (assemblyai only)
- `--no-diarize` — skip pyannote diarization for whisper-path transcription
- `--identify` — identify and remember recurring speakers by voice
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
- `nota enroll <history-id> <speaker-label> <name>` — enroll a stored per-speaker history clip

Commands exit non-zero if a referenced profile is missing. Confirmation lines
are written to stderr so stdout stays scriptable.

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
  panel, `Color(white: 0.09).opacity(0.9)` fill, hairline stroke, its own shadow
  inside a 24pt transparent margin (a window cannot draw outside its frame), and
  `colorScheme` forced dark in both system themes. Title row with a word count,
  a borderless editor with no bezel or focus-ring box, and a footer of Discard
  (esc, subdued) + Apply (⌘↩, accent). The buttons are drawn by the card rather
  than `.bordered`/`.borderedProminent`, which would put system light-mode
  chrome on a surface that has committed to being dark. Level is `.statusBar`,
  not `.floating`: activation used to be what raised the panel over a fullscreen
  app, and nothing does now.
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

- **The card is draggable, and it keeps its own position.** The **title row** is
  the handle (`DragGesture` → `DictationReviewPanel.dragChanged/dragEnded`), not
  the window background: this card contains a text view and a drag inside it has
  to select text, and AppKit's background drag reports nothing — "the owner
  chose this position" is precisely the fact that has to be remembered. The drag
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
  simply the **top-left**. One shared point would mean dragging either
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
  copies of the HUD material (`HUDSurface`) and their own meter
  (`HUDCompactMeter`) rather than refactoring the pill's into something shared.
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

## Key Design Decisions

- Nota is the primary name; MeetingSum references exist only for backward compatibility.
- Model registry (`src/registry.ts`) is the single source of truth: model id → task, provider, required API key env, base URL. Transcription models are statically curated; summary models are sourced dynamically from the auto-refreshed catalog (`src/catalog.ts` + `~/.nota/models-catalog.json`) with a baked in-repo fallback. Only the API keys the resolved models actually need are required.
- Summary model ids are auto-admitted weekly: mainline chat models (gpt-5.x, gemini flash/pro, deepseek v4+) matching allowlist predicates. Run `nota models list` for the current set.
- Summary default is key-aware: `deepseek-v4-flash` > `gpt-5.4-mini` > `gemini-3.6-flash` based on which API key is set. A hint is printed when DeepSeek is skipped despite being the cheapest option. CLI engines never join that chain (ADR 0003).
- A summary model that is not an endpoint is a first-class registry entry, not a special case: `claude-code/*` and `codex/*` carry `execution: "cli"`, and every decision about them is made on that kind — `requiresApiKey` (so a run is not refused for a key it was never going to use), `cliEngineFor` (which returns a spec or `undefined`, and is the argument the summary path branches on), `httpModelsForTask` (so no subprocess can reach dictation polish). The id is never pattern-matched. `makeSummaryCall` puts the HTTP client and the subprocess behind one shape, which is what lets the sectioned >100k-token flow route every section and the roll-up through a CLI engine without a second copy of the loop. See CLI Engines.
- A CLI engine's isolation from the owner's own agent configuration is a claim about *those* CLIs, so it is measured rather than assumed. A scratch cwd was assumed sufficient and was not: `claude -p` and `codex exec` both read a user-level guide out of the home directory whatever the cwd, and a meeting summary was being written under this machine's `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. The mechanism differs per engine because the CLIs differ — `--safe-mode` for one, a private `CODEX_HOME` for the other, since codex has no flag that reaches its AGENTS.md (`--ignore-user-config` and `project_doc_max_bytes=0` were both measured and both insufficient). Whichever mechanism is chosen must leave **auth** alone: `claude --bare` does the isolation and forces auth onto `ANTHROPIC_API_KEY`, which would move a run billed "included w/ subscription" onto a metered account. See CLI Engines.
- Pricing for summary models comes from the catalog via `computeSummaryCost` (tier-aware, ×1e-6 unit assertion). Pricing for transcription models remains a static table in `src/pricing.ts`.
- AssemblyAI as default provider: transcription + diarization in one API call ($0.15/hr)
- Whisper retained as fallback via `--provider whisper`
- `.qta` files auto-converted to `.m4a` via ffmpeg before AssemblyAI upload
- Speaker identity is a pure-Node ONNX d-vector pipeline: `onnxruntime-node` runs the WeSpeaker ResNet34-LM model over JavaScript-computed Kaldi fbank features, and stored L2-normalized embeddings are matched by cosine similarity. It needs no Python, hosted API, or identity-specific API key. The pinned model is downloaded on first use, checksum-verified, and cached at `~/.nota/models/wespeaker_en_voxceleb_resnet34_LM.onnx`; if the model or native runtime cannot load, identity no-ops with a clear message while the rest of the pipeline continues.
- Voice audio is captured **during** the pipeline run (the source audio is often a temp file deleted afterward): a short per-speaker PCM clip is saved under `~/.nota/history/<id>.assets/<label>.pcm`, and naming a speaker later enrolls an ONNX embedding from that stored clip, so enrollment works without the original audio. Speaker store schema v4 holds numeric d-vector arrays under `~/.nota/speakers.json`; incompatible v3 Eagle voiceprints are dropped with a warning and must be re-enrolled.
- Optional `--identify` recognizes enrolled speakers automatically and prompts for unknown ones (interactive TTY); freshly-typed names are enrolled inline from the captured clip
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
- Speaker identity (`--identify` and `nota enroll`) needs no API key or Python. It uses `onnxruntime-node` and auto-downloads its checksum-pinned ONNX model on first use.
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
