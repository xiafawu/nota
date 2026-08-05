# 0005 — Top-right chrome is global; bottom-right chrome is local

Date: 2026-08-05
Status: accepted

## Context

The app window accumulated affordances without a rule for where they go. The
toolbar's `.primaryAction` slot held whatever was current for the phase — Share
with a transcript open, Settings on home — and per-transcript work grew inline
in the content area, where `EnrichmentSlotView` occupied a permanent strip
above the transcript for a summary that is derived, not authored
(`MainPaneView.swift:237`, removed by the same effort as this ADR).

Two consequences. Placement was decided per feature and re-litigated every
time, and the answer was usually "next to the last button", so the toolbar
collected things that act on *one* transcript while the content area collected
chrome that is not content. Nothing in the codebase said which corner a new
affordance belonged in, so nothing could be wrong.

The immediate forcing function was the summary: lifting it out of the
transcript body into its own panel (XIA-415) needed a button, and there was no
principle to say whether that button went in the toolbar beside Share or
somewhere else. Deciding it for the summary alone would have been the same
per-feature call that produced the mess.

## Decision

**Top-right chrome is global. Bottom-right chrome is local.**

- **Global** — acts across all transcripts, or on the app itself. Lives in the
  window toolbar's trailing edge. Today: **History** (the drawer, ⌘L) and
  **Settings**.
- **Local** — acts on the transcript currently in front of the owner. Lives in
  the **content area's** bottom-right corner. Today: **Summary** and **Share**.

Two boundaries are easy to get wrong, and both are part of the decision:

**Metadata is not an action.** Speaker chips and tags are per-transcript and
they stay where they are — in `DocumentHeaderView` at the top of the content
area (`DocumentHeaderView.swift:45-62`) — because they *display state*. The
rule sorts actions, not everything that is per-transcript. A per-transcript
**action** on those chips (re-running identification, say) would belong
bottom-right. The generate-tags affordance is the near-miss that proves the
line: it sits on the tag row rather than in the corner, because it is the
action *of the thing displayed there*, attached to its object rather than
collected with the document's actions (XIA-416).

**The rule is about the content area's corners, not the window's.** The
toolbar is the *app's* chrome and belongs to the window; bottom-right is the
*document's* chrome and belongs to the content area. A local control floats
over the content, inset from the content area's trailing and bottom edges —
not pinned to the window frame, which would put it in the same visual class as
the toolbar it is meant to be distinguished from.

### The local cluster is two floating circles

Local controls are individual round glass buttons (34pt), icon-only with
tooltips, laid out along the bottom-right of the content area — not a single
bar with labels, and not one primary with an overflow menu.

Each control is its own object, which is what the Summary button needs: it
carries four states (outlined-plus when no summary exists, filled when it
does, a progress ring while generating, filled-with-a-warning-dot when stale —
XIA-416). On a circular button the ring *is* the outline. Inside a labelled
bar it would have to sit beside text without the label changing width
mid-generation, or the bar reflows while the owner watches it, and Share would
be moved by a state that is not its own.

## Consequences

- **Share moves** out of `ToolbarItem(placement: .primaryAction)`
  (`ContentView.swift:149`) into the bottom-right cluster beside Summary. The
  toolbar's trailing edge is left with History and Settings — global only.
- A new affordance has a question to answer before it has a position: *does
  this act on one transcript, or on all of them?* Placement follows, and a
  wrong placement is now wrong rather than merely unfamiliar.
- Share costs the same one click it always did, in a different corner. The
  owner has to learn one new location once.
- The **live-meeting phase** has no record and therefore no local actions; what
  the corner holds there is deliberately undecided, and is tracked as fog on
  the effort's map rather than answered here.
- The cluster and the summary rail occupy the same corner. The rail opens from
  the Summary button and covers it; nothing else is owed, because the rail is
  that button's own surface.

## Considered Options

- **Everything per-transcript in the toolbar** — Share and Summary beside
  History and Settings. One place to look, but it makes the toolbar mean
  nothing: four buttons, two scopes, no way to tell which is which without
  clicking.
- **Everything in the content area, toolbar reserved for the window** — pure,
  and it strands History, which is genuinely global and genuinely needs a
  persistent home.
- **A local bar with text labels** — no icon has to be guessed, and it states
  plainly that the two belong to the document. Rejected on the progress-ring
  reflow above, and on the width a labelled bar takes over the text column.
- **One primary button plus an overflow menu** — lightest footprint and an
  answer for the fourth local action before it exists. Rejected because Share
  would go from one click to two, into exactly the kind of menu this effort
  exists to empty out.
