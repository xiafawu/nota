# 0006 — One Details button, one panel; opening is free

Date: 2026-08-19
Status: accepted
Amends: 0005 (its "metadata is not an action" boundary)

## Context

A finished transcript had its facts in two places and its two entrances in two
corners.

The header (`DocumentHeaderView`) held the title, the "date · duration"
subtitle, the speaker chips, the record's fact strip and the tags. On scroll
those parts folded away, which changed the header's height, which changed the
scroll range that had decided they should fold — a state change driven by a
value it alters. The owner saw it as the transcript shaking, and saw it only on
short documents, which is the signature of that loop: a long document has range
to spare and never clamps. Two thresholds plus a range floor
(`DocumentHeaderCollapse`) damped the oscillation without removing it.

The first answer was to move those parts behind a toggle in the header, into a
`DocumentInfoCard` overlay. That killed the loop, because an overlay changes no
geometry. It also left the document with two buttons for its own facts: the
header's info toggle, and the local cluster's Summary button opening
`SummaryRailView` in the opposite corner. Each carried a dot of its own, for
two different pending decisions, and neither could name the other's.

The Summary button had a second problem that predates all of this. With no
summary it drew a `plus`, and one press both **started a generation** and opened
the rail to watch it — the dual-purpose click recorded as decision 10 in
`MainPaneView.swift`. That is why the button was `.disabled` during any
enrichment run, and why the whole of a document's metadata could not be put
behind it: a control that spends a model call is not a control an owner can
press to look something up.

## Decision

**One button, called Details, opening one panel that holds everything about the
open document.**

- The local cluster (ADR 0005's bottom-right corner) draws **Details**
  (`info.circle`) beside Share. The progress ring still replaces the glyph while
  a **summary** is generating. The `plus` state is gone.
- **Opening is free.** The button starts nothing and reverses with a second
  press. The only way to start a summary is a **Generate summary** button
  *inside* the panel, in the slot where the narrative would be. `.disabled` is
  gone with the click that needed it.
- **One panel, one scroll.** `SummaryRailView` gains, above its summary content
  and separated by a hairline, the four parts the info card held, in the card's
  order: the subtitle, the speaker chips, the record's fact strip, the tags.
  Not tabs, not a second card.
- **One dot, two claimants.** `DocumentInfoBadge.waiting(chips:isSummaryOutdated:)`
  lights the button's amber dot when a speaker chip holds a suggestion **or**
  the summary is stale; `DocumentInfoBadge.label(_:isGeneratingSummary:)` is the
  one string `.help` and `.accessibilityLabel` both read, and it names which one
  is waiting, or both.
- **A document with no history record keeps its button and its panel.** The
  cluster's `enrichment.record != nil` gate is deleted.
- **The header goes back to the title alone.** `DocumentInfoToggle` and
  `DocumentInfoCard` are deleted, with the header's `isInfoPresented` /
  `hasPendingDecision` / `onToggleInfo` parameters and `RichDocumentPane`'s
  info-card layer.

### What amends ADR 0005

0005 sorted **actions** into corners and left metadata where it was, on the
reasoning that chips and tags display state rather than act. That boundary held
while the header was a place metadata could live. It is not, and the reason is
the oscillation above: the header is measured against the scroll range and the
scroll range is measured against the header. Metadata is therefore in the
bottom-right corner too — not as an action, but as the *content of the one local
surface*, which is what the panel now is. The corner rule itself is untouched:
global chrome top-right, local chrome bottom-right, one cluster of round glass
buttons floating over the content.

0005 also said the local cluster's Summary button "carries four states
(outlined-plus when no summary exists, filled when it does, a progress ring
while generating, filled-with-a-warning-dot when stale)". Three survive. The
outlined-plus is gone, because it was the promise of the dual-purpose click.

## Consequences

- **The header cannot oscillate, and the arithmetic that damped it is deleted.**
  `DocumentHeaderView` reads one string and draws it.
  `RichTextViewer.onScroll` reports the offset alone; the scroll range existed
  for the collapse and has no reader.
  `ReadingColumnTests.testTheHeaderIsOneHeightWhateverTheDocumentCarries` now
  varies the *metadata* (bare, subtitle plus three tags, subtitle plus twenty)
  with the title held constant, which is a stronger claim than the version it
  replaces.
- **The panel's dismissal policy now governs the document's metadata too.**
  Someone who opened it to read a speaker's name must not lose an in-progress
  summary edit on the way out, so every close still runs
  `NotaModel.requestSummaryRailDismissal`. Nothing added to the panel routes
  around it. The panel is visually modal, so it also gained
  `.accessibilityAddTraits(.isModal)` with the backdrop hidden from
  accessibility, and Generate summary takes `.defaultAction`.
- **Two halves in one panel means one error channel serving two rows.** The
  controller's failure carries `EnrichmentController.errorField` (an
  `EnrichmentField`) rather than the activity it used to, or a failed tag add
  prints under the summary and relabels its button "Try Again", one press from
  a model call for an operation that was not a summary.
- **The in-flight fork has to name the summary specifically.**
  `SummaryRailView.summaryIsInFlight` branches on `activity == .summarizing`,
  the same predicate the button's ring uses, so a tag run cannot replace the
  narrative — or an open editor holding an unsaved draft — with a row reading
  "Generating tags" under a heading reading SUMMARY.
- **"No record" and "not read yet" became different answers.**
  `NotaModel.loadChips` clears the record synchronously and reads the real one
  off disk in a detached task, so every recorded transcript passes through
  `record == nil` on open. `SummaryRailView.summaryHalf(hasRecord:isResolvingRecord:)`
  is three states, fed by `EnrichmentController.isResolvingRecord`.
- **`DocumentInfoCard.subtitle(meta:facts:)` outlived its type.** It is the
  one-duration-per-surface rule and is now `DocMeta.subtitle(facts:)`, on the
  model rather than on any of the three surfaces that have drawn it.
- `parseDocumentMeta` is read two to four times per panel body evaluation, and
  the panel's own editor writes an `@Published` on the model it observes, so it
  stops at the first `## ` and enumerates lines rather than splitting the whole
  document first.

## Considered Options

- **Keep both buttons, and give the info toggle its own dot.** What shipped for
  two days. Rejected: the two dots mean the same thing to an owner ("something
  back here wants an answer") while pointing at two surfaces, and a document has
  one set of facts.
- **Tabs inside one panel** — Details and Summary side by side. Rejected: it
  is one document, and a tab is a place a waiting speaker suggestion can hide
  while the panel is open on the other tab.
- **Keep the dual-purpose click and put the metadata behind a second press.**
  Rejected outright: it makes the one control that spends money also the control
  an owner presses to check a speaker's name, and no dot or tooltip repairs
  that.
- **Hide the button on a document with no history record**, as the cluster did.
  Rejected: nothing about a document may disappear because of where it was
  opened from. An imported `.md` still has a subtitle, chips and tags; the panel
  omits the fact strip and the summary half and says so in one line.
- **Grey out Edit and Regenerate above the live Generate button.** Rejected:
  two dead controls above the live one, one of them naming an object that never
  existed, read as a summary that was tried and failed. They are absent instead.

---

## Addendum — 2026-09-02: the panel is the summary's only home

This ADR said the pane is the transcript and everything else is behind one
button. The code did not do it. `MarkdownRender` skips the header block and
begins the body at the **first `## `**, which on a summarized meeting is
`## Summary` — so the narrative, key topics, decisions and action items were
drawn in the document body *and* again in `SummaryRailView`, which reads all
four off the record. The same text, twice, in two places, on every meeting that
had been summarized. It went unnoticed because a transcript-only live meeting
has no `## Summary` at all.

Decided (owner, 2026-09-02): the copy in the **document body** goes. The pane
draws the title and the transcript, and nothing else. Two further changes come
with it, both from the owner's marks on a screenshot the same afternoon:

- The fixed header band is **removed**. The title becomes the first line of the
  scrolling document, in the reading column. The band existed to hold the
  metadata this ADR moved out; with the title alone left in it, a whole
  non-scrolling region was reserved for one line.
- The `## Full Transcript` heading is **removed**. The pane *is* the transcript;
  the heading labelled the obvious, and with the summary gone from the body it
  was the document's first line, where the title belongs.

Owed by this change: `SummaryRailView`'s summary half must fall back to parsing
the markdown's own `## Summary` section when `record == nil`. An imported `.md`
has no record, so with the body copy gone it would otherwise lose its summary
entirely — the exact failure this ADR's own rule forbids, that nothing about a
document may disappear because of where it was opened from.
