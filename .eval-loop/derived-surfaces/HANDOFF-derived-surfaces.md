# Handoff — derived surfaces in the app window: summary rail, unified history drawer, popover recents

Self-contained. Assume no prior conversation.

Repo: `/Users/xiafawu/Developer/Nota`

Branch: cut a fresh branch **off `master`** (e.g. `feat/derived-surfaces`).
`master` is at `c168908`. There is no in-flight feature branch to avoid. The
working tree is clean apart from untracked `.trace/` and `hatch-pet-mochi/`,
neither of which is yours to touch.

## Context

Nota is a TypeScript CLI (transcribe + diarize + summarize) with a native macOS
companion app in `macos/`. This change is entirely in `macos/` — no TypeScript.

Two surfaces that are *derived* from a transcript currently live in the wrong
places, and one exists but is unreachable:

1. **The summary** renders inline in the transcript view, in a permanent
   container (`EnrichmentSlotView`, `MainPaneView.swift:237`) that walks
   placeholder → in-flight → summary above the transcript text. It takes
   height from the transcript on every record, whether or not a summary
   exists.
2. **Dictation history** exists (`~/.nota/dictation-history.json`, 100-entry
   retention) but is only reachable from a standalone `Window` scene opened
   from the menu-bar popover. The owner reported not being able to find it
   from the app at all — and lost dictated text because of that.
3. **Share** sits in the window toolbar's `.primaryAction`, even though it acts
   on one transcript.

A four-ticket design effort settled all of this. **Every decision below is
locked** — see "Locked decisions". Your job is to build it.

The chrome rule the placements answer to is already committed as
`docs/adr/0005-global-vs-local-chrome.md` (read it — it is short and it is the
reasoning behind half this handoff) and `docs/glossary.md`.

## Hard constraints — do NOT touch

- **Any TypeScript.** `src/`, `tests/`, `package.json` dependencies. This is a
  Swift-only change.
- **`macos/Nota/Dictation/` except the three files named in the lanes below**
  (`DictationMenuBarView.swift`, `DictationHistoryView.swift` (deleted),
  `DictationHistoryStore.swift` — read-only, see below). The dictation HUD,
  the review card, `TextInjector`, `StreamingDelivery`, `DictationController`'s
  session machinery are all out of scope.
- **`DictationHistoryStore.swift` is read-only to you.** No schema change, no
  new field on `DictationHistoryEntry`, no change to
  `defaultRetentionLimit`. Pinning was explicitly rejected for dictation
  entries (see decision 14).
- **`DictationController.retryDictationHistory` / `retryTarget`
  (`DictationController.swift:1771-1826`)** — behavior unchanged. You call
  them; you do not rewrite them. Their existing failure message is the one the
  UI shows.
- **`strippingEnrichmentSections`** in `EnrichmentController.swift` — **stays**,
  unchanged and still called. Deleting it would render the summary inline again,
  which is the exact thing this change undoes. Copy and export keep using the
  full markdown.
- **The speaker chips** in `DocumentHeaderView.swift` — display only, no new
  affordance on them. See decision 8.
- `docs/adr/0005-global-vs-local-chrome.md` and `docs/glossary.md` — already
  written and committed. Do not edit them.

## Locked decisions

### The summary rail

| # | Decision |
|---|----------|
| 1 | The summary is a **SwiftUI overlay in the window's `ZStack`**, the same mechanism `historyDrawerLayer` uses (`ContentView.swift:101`). **Not** a `Window` scene, **not** an `NSPanel`. |
| 2 | Fixed width **380pt** (matching the history drawer), full height minus insets, **anchored bottom-right**, growing up the right edge — it rises from its own button rather than from the opposite corner. |
| 3 | The compact/expanded states, the divider drag, and the 92 / 260 / 360pt heights are **retired**. A rail has one size. `SummaryDrawerLayout`'s height math goes; `preview(for:)` may stay if something still uses it, otherwise it goes too. |
| 4 | `structuredSummary`'s two-column branch (`MainPaneView.swift:718`, threshold `twoColumnMinWidth = 480` at `:262`) is **left exactly as written**. At 380pt it permanently takes the stacked arm. Do not delete the branch, do not lower the threshold, do not swap in `ViewThatFits` — the comment there records that `ViewThatFits` was already tried and rejected. |
| 5 | The rail holds: title, Edit, Regenerate (confirm-gated, as today), Close; narrative; topics; decisions; action items; the `summaryOutdated` banner; the in-flight row (model name + Cancel); failures with Retry. All of these move out of `MainPaneView` wholesale. |
| 6 | **Record switching closes the rail.** Opening a different transcript closes it; leaving the document phase (home / running / live meeting) closes it. It does not follow the new record. |
| 7 | A dirty draft still commits (or asks — decision 11) on that close, since it is that record's text. |

### The buttons

| # | Decision |
|---|----------|
| 8 | The **bottom-right local cluster** is **two individual round glass buttons, 34pt, icon-only with tooltips** — not a labelled bar, not one primary plus an overflow. Inset from the *content area's* trailing and bottom edges, floating over the content. Never pinned to the window frame. |
| 9 | **Summary button, four states.** No summary → outlined icon with a plus, tooltip "Generate summary". Summary exists → filled, "Summary". Generating → progress ring; clicking it **opens the rail** (Cancel lives inside the rail, not on the button). Stale (`summaryOutdated`) → filled with a small warning dot. |
| 10 | The Summary button is **dual-purpose**. With no summary, one click **starts generation AND opens the rail immediately**, showing the in-flight row; text fills in place. With a summary, one click opens the rail. There is no path to an empty rail, which is why the dashed-border "No summary yet" placeholder card retires. |
| 11 | **Share moves** out of `ToolbarItem(placement: .primaryAction)` (`ContentView.swift:149`) into the cluster beside Summary. The toolbar's trailing edge is left with History + Settings only. The `ShareMenu` view itself is reused as-is; only its host changes. |
| 12 | **Staleness is marked on the Summary button and nowhere else.** No marker at the speaker chips, not even a transient one. |

### Editing dismissal

| # | Decision |
|---|----------|
| 13 | A **new app setting** controls what dismissing the rail with unsaved edits does. **Both** dismissal gestures follow it — one switch, no per-gesture split. `Save it` (**default**) commits the draft and closes. `Ask me` shows a confirm: save / discard / keep editing. Under the default, **Escape commits** while editing, inverting its usual meaning; that is the owner's call, taken knowingly. |

### The history drawer

| # | Decision |
|---|----------|
| 14 | `HistoryDrawerView` gains a **two-segment segmented control** under the search field: **Transcripts** / **Dictation**. **Bare labels — no counts on the control.** |
| 15 | Under the switch, a **meta line**: `18 transcripts` on the left, `42 dictations · last 100` on the right. Both counts always visible. The dictation count carries the retention qualifier — it is a ceiling, not a total. |
| 16 | **A dictation row expands and copies on one click.** The row opens in place to its full text AND the text goes to the clipboard; the expansion is the receipt. One row open at a time. Inside the expanded row: **Insert again** and **Delete** as labelled buttons. |
| 17 | **Search filters the active tab**, and while a query is live the **inactive** segment carries a small badge with its match count. The badge disappears when the query clears. Transcript matching stays `HistoryPresentation.matches`; dictation matching is a case-insensitive substring over `entry.text`. |
| 18 | **No pinning on the Dictation tab.** The Pinned section does not render there and those rows carry no pin icon. |
| 19 | **Four distinct empty states.** (a) Never dictated: "No dictations yet" + how to start + "Completed dictation stays here if insertion needs to be retried." (b) No transcripts: today's "No transcripts yet" + a route in (drop a file / share to Nota); footer names the other tab's count. (c) Query matched nothing on this tab: names the query, offers the crossing ("3 matches in Transcripts →" — the badge from decision 17 already computes it). (d) Query matched nothing anywhere: names the query and **how much was searched** ("Not in 18 transcripts or 42 dictations") + Clear search. |
| 20 | The Dictation tab keeps a footer privacy line: *Stored on this Mac · audio never saved*. |
| 21 | **No bulk clear in the drawer.** Per-row delete only. The old "Clear History" button and its confirm alert are not reproduced anywhere in this change. |

### The menu bar

| # | Decision |
|---|----------|
| 22 | `Window("Dictation History", id: "dictation-history")` (`NotaApp.swift:73`) is **deleted**, and `macos/Nota/Dictation/DictationHistoryView.swift` is **deleted outright**. |
| 23 | The popover gains a **Recent dictations** section above the existing menu items, holding the **three** newest entries. |
| 24 | Popover row: up to two lines of text, then `2:44 PM · Slack` and the status label. **Click copies.** **Hover replaces the status text with `↩ Insert again`** on that row, which calls the existing `retryDictationHistory`. No ⌥-click modifier. |
| 25 | The section **always renders**. With nothing in it, one italic line: *Finished dictations appear here.* |
| 26 | Below the rows: `Show all N in Nota →`, which opens the main window and the drawer on the Dictation tab. This is the only route in the popover that needs the app window. |
| 27 | The old `Dictation History (42)` menu item and `openHistoryWindow()` (`DictationMenuBarView.swift:160`) are removed — the section replaces them. |

### Tags

| # | Decision |
|---|----------|
| 28 | The generate-tags affordance goes **on the existing tag row** in `DocumentHeaderView.swift` (around `:54-59`, where `EditableTagRow` / the static chips already render): "Generate tags" when empty, a `+` when not. Tagging progress and failure show on that row. |
| 29 | **`EnrichmentSlotView` is deleted outright** (`MainPaneView.swift:237`), along with `EnrichmentSlotState`'s slot-only cases. The transcript view keeps **nothing** between the header and the transcript. |

## Task — one sequential prelude, then four parallel lanes

**Lane 0 must land first and alone.** It is the shared-file phase; every other
lane builds on it. Lanes 1–4 own disjoint files and may run as an agent team.
One commit per lane.

### Lane 0 — wiring (SEQUENTIAL, first, alone)

Owns: `macos/Nota/UI/ContentView.swift`, `macos/Nota/App/NotaApp.swift`,
`macos/Nota/App/NotaModel.swift`.

- Remove `ShareMenu` from the `.document` arm of
  `ToolbarItem(placement: .primaryAction)` (`ContentView.swift:149`). Leave the
  `.home` Settings arm and the History command alone.
- Delete the `Window("Dictation History", id: "dictation-history")` scene
  (`NotaApp.swift:73`).
- Add the **summary rail layer** to the same `ZStack` that hosts
  `historyDrawerLayer` (`ContentView.swift:101`), anchored `.bottomTrailing`,
  gated on a new `@Published var isSummaryRailPresented` on `NotaModel`
  (alongside `isHistoryDrawerPresented`, `NotaModel.swift:185`). Same
  click-outside + hidden `.cancelAction` Escape treatment — but Escape's
  behavior while *editing* follows decision 13.
- Pass the `dictationController` into `HistoryDrawerView` so lane 2 has it.
- Add the editing-dismissal setting's storage to `NotaModel` (same
  `UserDefaults`-backed `@Published` shape as `identifySpeakers`,
  `NotaModel.swift:18`), defaulting to **Save it**.
- Add the rail-closing rules from decision 6 (record switch, leaving the
  document phase) wherever the phase and current record already change.

Lane 0 should compile with stubs where lanes 1–4 will fill in. **Do not
implement the rail's contents, the drawer's tabs, the popover section, or the
tag affordance here.**

### Lane 1 — the summary rail and the local cluster · parallel-safe

Owns: `macos/Nota/UI/MainPaneView.swift`,
`macos/Nota/UI/EnrichmentController.swift`,
`macos/Nota/UI/SummaryDrawerLayout.swift`, a new
`macos/Nota/UI/SummaryRailView.swift`, `macos/Nota/UI/SettingsView.swift`.

Decisions 1–13, 29. Delete `EnrichmentSlotView` and move everything the rail
holds out of `MainPaneView`. Build the two-button cluster. Add the
editing-dismissal picker to Settings (General), reading the `NotaModel`
property lane 0 added.

### Lane 2 — the unified history drawer · parallel-safe

Owns: `macos/Nota/UI/HistoryDrawerView.swift`.

Decisions 14–21. The dictation row is new here; do not import
`DictationHistoryView`'s list idiom (selection + footer buttons) — it is being
deleted and its shape was rejected for a 380pt overlay.

### Lane 3 — the popover recents, and retiring the window · parallel-safe

Owns: `macos/Nota/Dictation/DictationMenuBarView.swift`, and **deletes**
`macos/Nota/Dictation/DictationHistoryView.swift`.

Decisions 22–27. `Show all in Nota →` must open the main window *and* land on
the Dictation tab — coordinate through `NotaModel` state lane 0 added, not by
reaching into the drawer view.

### Lane 4 — the tag row affordance · parallel-safe

Owns: `macos/Nota/UI/DocumentHeaderView.swift`.

Decision 28. Do not touch the speaker chips in the same file beyond leaving
them exactly as they are (decision 12 and the ADR's "metadata is not an
action" boundary).

## Stop-fence

**THIS CHANGE ONLY.** Do not:

- touch any TypeScript, the CLI, or the pipeline;
- change `DictationHistoryStore`'s schema, retention limit, or file format;
- change `TextInjector`, `retryTarget`, or any dictation *session* code;
- add pinning, starring, or bulk-clear to dictation entries;
- "improve" the dictation HUD, the review card, or the streaming path;
- add light-mode support, change `GlassTint`, or touch the dictation surfaces'
  appearance — that is a separate effort, deliberately out of scope;
- decide anything about the **live-meeting phase**. It has no record. The
  cluster and the rail simply do not appear there; if a question arises about
  what that phase should show, leave it as-is and say so in your report;
- edit `docs/adr/0005-*` or `docs/glossary.md`.

## Verify

Run all of these and paste **real output**:

1. `npm test` — the TypeScript suite. Expect all green. It exercises none of
   this, but a red suite means something else is broken and I want to know.
2. `npm run build:macos` — **must** print `** BUILD SUCCEEDED **`.
   Non-negotiable gate: this is a Swift-only change and the TS suite says
   nothing about it.
3. `macos/NotaTests/run-tests.sh` — the Swift unit tests. **Part of the fence:**
   name the results for any test class touching the surfaces you changed, and
   name the tests you added or updated. A report without Swift test results is
   incomplete.
4. `grep -rn "DictationHistoryView\|dictation-history\"" macos/` — must return
   **nothing** but `DictationHistoryStore.swift`'s file path constant. A
   dangling reference to a deleted view or window id is a build failure waiting
   for a different configuration.
5. `grep -n "strippingEnrichmentSections" macos/Nota/UI/EnrichmentController.swift`
   and its call site — must still exist and still be called. Paste both.

### Tests required, not optional

- `SummaryDrawerLayout`'s existing tests, if any, must be updated rather than
  deleted wholesale — say which assertions you removed and why.
- A test that the editing-dismissal setting's **default is Save it** and that a
  payload written without the key decodes to that default rather than throwing.
- A test for the dictation search predicate (case-insensitive substring over
  `entry.text`), and one for the inactive-tab match count.

## Cannot verify without the owner's machine

Do not attempt these and do not work around their absence — they need a human
at a real screen with Accessibility granted, and will be run here after merge:

- the rail rises from the bottom-right button and closes on record switch;
- Escape with a dirty draft commits under the default setting;
- the Summary button shows all four states, including the ring during a real
  generation;
- Share still works from its new home;
- the popover's hover `↩ Insert again` actually inserts into a still-running
  target app;
- `Show all in Nota →` opens the window on the Dictation tab from a cold state
  where no main window exists.

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
