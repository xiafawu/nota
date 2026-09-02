# Checkpoint — 2026-08-25

Session domain: XIA-441, the document surface. Ended clean: working tree has no
modified tracked files, and `master` is pushed through `523321f`.

## What shipped

`523321f feat(macos): the record's facts and its summary are behind one button (XIA-441)`

The header carries the **title alone**. The subtitle, the speaker chips, the
fact strip, the tags and the summary are **one panel** opened by **one Details
button** (`info.circle`) in the bottom-right local cluster beside Share.
`DocumentInfoCard` and `DocumentInfoToggle` are deleted — they were the
intermediate design (a header ⓘ toggle opening an overlay card, plus a separate
Summary button opening the rail) and they lasted two days.

Six decisions the owner made in the grilling, all implemented:

1. **One button**, not two. Details, `info.circle`, beside Share.
2. **Opening is free; generating is not.** The old dual-purpose click (a press
   with no summary spent a model call *and* opened the rail) is gone with the
   `plus` glyph that promised it, and so is its `.disabled`. The only way to
   start a summary is the **Generate summary** button inside the panel.
3. **One panel, one scroll**: subtitle → chips → fact strip → tags → hairline →
   summary. Not tabs. The artifact rendered both of B's tab states side by side
   precisely because the cost of tabs is entirely in the tab you are not looking
   at; the owner chose one scroll after seeing it.
4. **One amber dot, two claimants.** `DocumentInfoBadge.waiting(chips:isSummaryOutdated:)`
   lights for a pending speaker suggestion **or** a stale summary, and
   `DocumentInfoBadge.label(_:isGeneratingSummary:)` is the one string `.help`
   and `.accessibilityLabel` both read, naming whichever is waiting.
5. **A document with no history record keeps its button and its panel.** The old
   `enrichment.record != nil` gate meant an imported `.md` had no way in at all.
6. Header back to title only. `testTheHeaderIsOneHeightWhateverTheDocumentCarries`
   is what removed the shake for good — a header that cannot change height cannot
   oscillate against the scroll range that decided it should fold.

Also on `master`, pushed the same day: `517f7ae` and `1acaca9`, the two earlier
scroll-shake fixes.

## The three latent bugs the review caught

Each was reachable before and became one click apart after the merge. All three
are "the panel says something it cannot support":

- **A tag run is not a summary run.** The in-flight fork branched on
  `activity != .idle`, so one press on Generate tags replaced the narrative — or
  an open editor holding an unsaved draft — with a progress row reading
  "Generating tags" under a heading reading SUMMARY. Now `activity == .summarizing`,
  the same predicate the Details button's ring uses.
- **"No record" and "not read yet" are different answers.** `NotaModel.loadChips`
  clears the record synchronously and reads the real one off disk in a detached
  task, so every recorded transcript passes through `record == nil` on open —
  and printed an imported-file notice under a populated fact strip.
  `EnrichmentController.beginRecordLookup` / `isResolvingRecord` plus a
  three-state `summaryHalf(hasRecord:isResolvingRecord:)` fix it, and the notice
  states the absence only, claiming no provenance.
- **A failure belongs to the row it happened in.** `EnrichmentController` has one
  error channel and both halves of the panel draw out of it, so a failed tag add
  printed under the summary and relabelled its button "Try Again" — one press
  from a model call for an operation that was not a summary. The failure now
  carries `errorField: EnrichmentField?` rather than the activity.

Plus a performance fix: `parseDocumentMeta` re-split the whole `.md` 2–4× per
body evaluation on the surface the owner types into (the `TextEditor` writes an
`@Published` on the model it observes). It now uses `String.enumerateLines` and
stops at the first `## `. That is the publisher-rate × observer-breadth trap
this codebase has recorded three times, arriving as parse cost rather than view
cost.

## Verification

- `Executed 640 tests, with 0 failures (0 unexpected)` / `** TEST SUCCEEDED **`.
  The known `PasteInjector.capture` Signal 11 clipboard race did not fire on the
  final run.
- `npm run deploy:macos` exited 0; `/Applications/Nota.app` signed with the
  stable "Nota Local Signing" identity.

## Docs

- `CLAUDE.md` → "The Document Surface" **rewritten** against the tree, not
  appended to. Cites ADR 0006.
- `docs/adr/0006-one-details-button-one-panel.md`, new.

## Open, in the order they are likely to come up

- **XIA-441 Stage 2** — speaker as its own row, timestamps permanently in the
  gutter. Touches selection, copy, RTF export, and the marker pips.
- **XIA-448** — re-transcribe an interrupted record. Filed, never started. Today
  a crash mid-session keeps the audio and the markers and loses the transcript,
  with no verb to recover it.
- **XIA-439** — VoiceOver on the recording cluster.
- **XIA-437 / 438 / 440** — probably dead; worth reading and closing.
- **XIA-427, XIA-413, XIA-428** — carried from earlier sessions.

## Untracked and deliberately left alone

`.claude/checkpoint-*.md`, `.claude/design-2026-08-09/`,
`.claude/workflow-2026-08-10-field-background/`, `.trace/`, `hatch-pet-mochi/`.
