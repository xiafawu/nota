# Handoff — the review/dictation card is dragged from anywhere but its editor

Self-contained. Assume no prior conversation.

Repo: `/Users/xiafawu/Developer/Nota`

Branch: cut a fresh branch **off `master`** (e.g. `fix/review-card-drag-anywhere`).
There is no in-flight feature branch to avoid; `master` is at `f5e6dd4` and the
working tree is clean apart from untracked `.trace/` and `hatch-pet-mochi/`,
neither of which is yours to touch.

## Context

Nota is a TypeScript CLI (transcribe + diarize + summarize) with a native macOS
companion app in `macos/`. The app has a dictation feature whose text can be
delivered three ways (`DictationSettings.deliveryMode`): `.immediate`,
`.streaming`, and `.review`.

In `.review`, a floating card (`DictationReviewPanel`) is the session's **one and
only** surface — it opens when the hotkey goes down, shows the live draft inside
its editor while recording, and holds the finished text for the owner to Apply or
Discard. The HUD pill never appears in that mode at all (`isReviewing`
short-circuits `HUDState.compute`). This "one component" merge landed 2026-08-03.

Both floating surfaces are draggable and remember where the owner put them. The
pill claims its whole surface as a handle (`HUDDragView`); the card does not —
and that is the bug below.

## Hard constraints — do NOT touch

- `macos/Nota/Dictation/DictationHUDPanel.swift` — the pill, its `HUDDragView`,
  and `HUDPositionStore`. The pill has no defect; leave the file untouched.
- `ReviewPositionStore`, `ReviewPanelLayout.validatedTopLeft`, and
  `DictationReviewPanel.dragChanged()` / `dragEnded()` — the storage and the
  window-moving mechanics are correct and stay exactly as they are. You are
  moving *where the gesture is attached*, nothing else.
- `isMovableByWindowBackground = false` on the panel — stays false. AppKit's
  background drag reports nothing back, and "the owner chose this position" is
  precisely the fact `ReviewPositionStore` has to record.
- `ReviewEditor` / `BottomAlignedTextView` behavior — text selection, the dimmed
  draft suffix, the read-only-while-recording flag. Do not modify the editor.
- Anything outside `macos/Nota/Dictation/` — no TS, no CLI, no other UI.

## Locked decisions

| # | Decision |
|---|----------|
| 1 | The whole card is a drag handle **except** the editor and the two buttons. |
| 2 | The handle moves from `metaRow` to the card's **outer container** (the root of `DictationReviewView.body`). The meta row keeps no gesture of its own — one handle, not two. |
| 3 | Same gesture as today: `DragGesture(minimumDistance: 2)` → `model.onDragChanged?()` / `model.onDragEnded?()`. Do not invent a new mechanism. |
| 4 | The editor keeps its mouse. `ReviewEditor` hosts an `NSTextView`, which consumes mouse-down itself and never forwards to a SwiftUI ancestor, so a drag starting on text must still select text. |
| 5 | Discard / Finish-Apply keep their clicks. SwiftUI buttons take precedence over a container gesture; verify, don't assume. |
| 6 | The card's geometry, size, and stored anchor (top-left) are unchanged. This is an input change, not a layout change. |
| 7 | `isMovableByWindowBackground` stays `false` (see constraints). |

## Task — single lane, sequential

One file, one commit. **Do not use an agent team**: every change is in
`macos/Nota/Dictation/DictationReviewPanel.swift` (plus its test file), so
parallel lanes would collide.

1. In `DictationReviewView.body` (around line 1000), attach to the root `VStack`
   — after its existing modifiers, in a position where it covers the padding and
   the glass margin — a `.contentShape(Rectangle())` and the drag gesture:

   ```swift
   .gesture(
     DragGesture(minimumDistance: 2)
       .onChanged { _ in model.onDragChanged?() }
       .onEnded { _ in model.onDragEnded?() }
   )
   ```

2. Remove the identical `.contentShape(Rectangle())` + `.gesture(...)` pair from
   `metaRow` (around lines 1058–1064). The row stays visually identical; it just
   stops being the sole handle.

3. Update the comments that describe the handle. Several places state the meta
   row is the drag handle and must not go stale — at minimum:
   - the `metaRow` doc comment,
   - the `isMovableByWindowBackground = false` comment in `DictationReviewPanel.init`
     (around line 653),
   - the panel-level doc comment near line 616 that says "this card is dragged by
     one row and its editor must keep text selection everywhere else, so nothing
     here may claim every point" — that reasoning still holds for
     `GlassBackingView` (it must not claim points the way `HUDDragView` does), but
     the "one row" half is now wrong.

   Explain *why* the editor is still safe: it is an AppKit text view that handles
   its own mouse events, which is what lets the container own everything else.

4. Add a test to `macos/Nota/Dictation/Tests/DictationReviewTests.swift` covering
   the wiring that is testable without a window server: that
   `DictationReviewModel.onDragChanged` / `onDragEnded` are invoked and reach the
   panel's recording path. If the existing suite already covers the callbacks,
   extend rather than duplicate, and say so in your report. A test that merely
   asserts SwiftUI modifier order is not wanted — do not write one.

## Stop-fence

**THIS TASK ONLY.** Do not:
- touch the HUD pill, its drag view, or its position store;
- add a drag affordance, grabber glyph, hover cursor, or any visual change;
- change the card's size, layout, rows, or stored anchor;
- "improve" the editor, the buttons, the glass plate, or the streaming path;
- refactor `DictationReviewPanel.swift` beyond the lines this task names.

## Verify

Run all of these and paste **real output**:

1. `npm test` — the TypeScript suite. Expect all green. (It exercises none of
   this, but a red suite means something else is broken and I want to know.)
2. `npm run build:macos` — **must** print `** BUILD SUCCEEDED **`. This is a
   Swift change; the TS suite says nothing about it. Non-negotiable gate.
3. `macos/NotaTests/run-tests.sh` — the Swift unit tests. Name the test class
   results for `DictationReviewTests` explicitly, including the test you added or
   extended in step 4. Required, part of the fence: a report without
   `DictationReviewTests` results is incomplete.

## Cannot verify without the owner's machine

The four interaction checks need a human at a real screen with Accessibility
granted, and I will run them here after merge — do not attempt them, and do not
work around their absence:

- drag from the glass margin → card moves;
- drag from the meta row → card still moves;
- drag across text in the editor → text selects, card stays put;
- click Discard / Finish / Apply → the button fires, card stays put.

## Required reply template

```
Reply using exactly these sections:
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine/data)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
```
