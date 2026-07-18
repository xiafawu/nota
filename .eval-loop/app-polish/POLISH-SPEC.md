# POLISH-SPEC — app-wide fit-and-finish (locked)

Source of truth for the polish implementation. Verdicts locked in
[D1](tickets/D1-adjudicate-catalog.md) (56/57 accepted; S8 key-capture recorder
deferred). Defect detail lives in the catalogs: [A1](assets/A1-catalog.md)
[A2](assets/A2-catalog.md) [A3](assets/A3-catalog.md) [A4](assets/A4-catalog.md)
[W1](assets/W1-catalog.md). This spec assigns every accepted finding to a lane, fixes
the file fences, and defines verification.

## Hard constraints (all lanes)

- **No new features.** Polish only; structure changes only where a finding approves them.
- **Dark-capsule HUD direction is immutable** (solid dark capsule, forced dark scheme).
- **Do not edit `Tokens.swift` / `Metrics.swift`** except Lane MAIN (single owner);
  other lanes add local constants.
- Tests asserting old behavior (state strings, layouts) are updated IN-lane with the
  change and reported — never silently deleted.
- Each lane = one branch `polish/<lane>`, self-contained commits, no cross-lane files.

## Lanes and their findings

### Lane MAIN — main window (chrome, dashboard, document, running)
Files: `ContentView.swift`, `MainPaneView.swift`, `HomeDashboardView.swift`,
`EmptyMainView.swift`, `DocumentHeaderView.swift`, `RichTextViewer.swift` (touch only if
header collapse needs it), `Tokens.swift`/`Metrics.swift` (owner), `ToolbarStatusPill.swift`.
- A1-H1: toolbar regains material/scroll-edge treatment when content scrolls beneath (all
  three views); the at-rest borderless look may stay.
- W1-1: animate home↔document swap at the `ContentView.body` branch (fade or fade+8pt
  rise, matching HUD motion), driven by `withAnimation` at the state changes.
- A1-T1: status pill shows only during runs; hidden in completed document view.
- A1-H2: one card material + radius scale across hero/cost/rows.
- A1-H3: history rows become real Buttons with hover wash + pressed state.
- A1-H4: Recent gains recency grouping or short absolute dates.
- A1-H5–H9: tail truncation, "Transcript" fallback title (filename+date), fixed-height
  loading/error skeleton in the cost card, no orphan divider when empty, adaptive
  expanded-table columns.
- A1-D1: document header collapses/scrolls away with content (scroll-edge fade minimum;
  collapse preferred).
- A1-D2: speaker chip shows final name only; mapping moves to popover/tooltip.
- A1-D3: distinct per-speaker dot colors, echoed on transcript speaker names.
- A1-D4: header and body share one leading edge.
- A1-R1: running view shows staged progress (validate → transcribe → summarize → write)
  with animated phase transitions.
- A1-R2: window title carries the filename during a run.

### Lane HUD — dictation HUD
Files: `DictationHUDPanel.swift`, `DictationHUDController.swift`,
`DictationHUDState.swift`, `MicCapture.swift`.
- A3-P1: anchor = frontmost app's focused window (AX) or bottom-center of the active
  screen; never Nota's own windows.
- A3-P2: position once per show/session; reposition only on screen-parameter change.
- A3-P3: account for the 24pt shadow margin in position math.
- A3-M1: dB transfer curve (20·log10, ~−50dB floor, normalized) + fast-attack/slow-release.
- A3-M2: subtle time-driven idle breathing (TimelineView phase term).
- A3-L1: auto-hide consumes the underlying state (clear lastPolishWarning /
  lastSecureFieldNotice / lastProcessedText on hide) — kills the resurrect bug.
- A3-L2: success auto-hide 2s when a snippet is shown.
- A3-L3: fatal errors persist longer than warnings (≥6s or until next trigger).
- A3-V1–V3 (verify-then-fix): dark-on-dark separation, warning-vs-error distinguishability
  (consider glyph + tint pairing), two-line capsule shape.
- A3-A1: post NSAccessibility announcements on listening/success/error transitions.

### Lane SETTINGS — settings window
Files: `SettingsView.swift`, `DictationSettingsView.swift`, `SpeakersSettings.swift`.
- W1-2: remove Speakers-tab window-toolbar items ("New" dead control per A2-S5; Refresh
  folds into the pane); `.listStyle(.inset)` master list — tab strip owns the toolbar.
- A2-S1: Dictation form adopts the Models pattern — section header carries the label,
  controls `.labelsHidden()`; no header/label duplication.
- A2-S2: per-tab ideal height, fixed width.
- A2-S3: API keys labeled by provider name; env var as caption.
- A2-S4: key rows become status rows; input field appears on "Replace…".
- A2-S11: "Remove" action per key (delete from ~/.nota/config).
- A2-S6: embedding dims / raw source paths behind a "Show details" disclosure.
- A2-S9: drop `.roundedBorder` inside grouped Forms.
- A2-S12: privacy text becomes the Polish section footer.
- A2-S13: Enter commits rename (`.onSubmit`).
- A2-S7: one help-text idiom (footers).
- A2-S10: CLI jargon out of UI copy (merge caption, empty state, delete alert).
- ~~A2-S8 key-capture recorder~~ — DEFERRED, do not implement.

### Lane MENUBAR — status item, popover, onboarding
Files: `DictationMenuBarView.swift`, `DictationTypes.swift`.
- A4-B1: icon-only MenuBarExtra label (symbol per state stays; text stays as a11y label).
- A4-B4: add "Settings…" (SettingsLink/openSettings) and "About Nota" to the popover.
- A4-B5: full-width hoverable row style for popover actions.
- A4-B6: remove the latency line.
- A4-B2: statusTitle wording — finalizing "Working…", injecting "Inserting…", failed
  something actionable. Update HUD/state tests accordingly.
- A4-B3: symbol swap for finalizing/injecting (progress-flavored family).
- A4-B7: "Last:" snippet capped at 2 lines, tail-truncated.
- A4-B8: single source for the disabled explanation (drop the duplicate paragraph).
- A4-B9: plain "Quit Nota" (no power icon).
- A4-B10: delete dead `diagnosticsSummary`.
- A4-B11: onboarding drops Developer-ID/notarization jargon; plain-language caption.
- A4-B12: auto-poll permissions while onboarding visible; drop the Refresh button.
- A4-B13: grant links read "Grant in System Settings…".

## Verification (every lane)

1. `npm run build:macos` exits 0 (script prints the .app path last).
2. `cd macos && xcodegen generate && xcodebuild test -project Nota.xcodeproj -scheme
   Nota -destination 'platform=macOS'` → `** TEST SUCCEEDED **` (both bundles).
3. Screenshot verification happens post-merge from the main session (deployed build,
   window-id captures) — lanes report what to look at.

## Shipping order

Review/merge order: MAIN → HUD → SETTINGS → MENUBAR (chrome-first per D1; lanes build in
parallel, merge sequentially with conflict-free fences). Each merge: full suite green,
deploy, screenshot-verify, then next.
