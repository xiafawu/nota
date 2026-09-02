# Checkpoint — 2026-09-02 (overnight polish run)

Session domain: a full polish pass over the macOS app — theme consistency,
colours working together, animation, gesture — run unattended from 01:20 to
~05:15 PDT with Opus 5 subagents while the owner slept. **Nothing touched
master.** Everything is on `polish/overnight-2026-09-02` (forked from master
`523321f`), 37 commits, 65+ files, +2.9k/−0.6k. Not pushed, not deployed.

## How it was run

1. Four read-only Opus auditors in parallel (colour/theme, motion, gesture,
   layout/type/copy) → 48 findings with file:line evidence, each ranked and
   given a concrete fix. Findings that contradicted a CLAUDE.md rule were
   excluded by construction; findings that showed code VIOLATING a rule were
   the point.
2. Findings grouped into 16 batches by theme and file locality. Each batch went
   to one Opus implementer in its own git worktree, two lanes at a time on
   disjoint files. Every implementer ran the full `xcodebuild test` gate, wrote
   pinning tests, committed with trailers, rebased onto the polish branch, and
   reported. I reviewed each diff from the parent tree and `--ff-only` merged.
3. Final gate on the merged branch (see Verification).

Audit files and the run log are in the session scratchpad
(`polish-run.md`, `backlog.md`, `audit-A..D.md`) — worth copying into
`.claude/` if you want them to outlive the session.

## What shipped, by batch (37 commits, all `fix(macos): … (polish)`)

1. **Motion vocabulary + Reduce Motion** — one hover speed
   (`Tokens.hoverDuration` 0.15, `animSnap` built from it), one pop-in
   transition (`Tokens.popIn(reduceMotion:)`), the phase cross-fade stops
   sliding 8pt under Reduce Motion, the HUD meters read
   `RecordingMotion.meterAnimation`, symbol pulses stop under Reduce Motion,
   every hover wash reads `Tokens.rowHoverWashOpacity`. Dead
   `toolbarStatusTint` token + its tuning slider deleted.
2. **Colour semantics** — `CraftTokens.failure` (= `stopRed`) is the one red
   for a failed job (was orange in two places, red in three);
   `LocalCluster.prominentTint` (= `primaryBlue`) so Details/Share and Mark are
   one blue; `HUDInk.finalized/volatile/listening` — the HUD's "mic open" mark
   is no longer the error's red (neutral white; the ember is forbidden there).
3. **Glass double rim** — `craftGlassPanel` draws its hairline only on the
   Reduce Transparency branch (`.regularMaterial` has no rim); Liquid Glass
   carries its own. Nine surfaces. Geometry constants unchanged. CLAUDE.md's
   Reduce Transparency paragraph updated.
4. **Ink on the ground (a)** — the empty / in-progress pane, the document
   title and its hairline draw `GroundInk` tiers instead of label colours;
   dead second speaker-chip view deleted.
5. **Live transcript follow** — `LiveTranscriptFollow.decide` +
   `RecordingPaneMetrics.followSlack` (24): the transcript follows the newest
   line only while you are at the bottom; content growth is not "scrolling
   away"; scrolling back down resumes. No new control. CLAUDE.md bullet added.
6. **Panel arrivals** — `PanelMotion` (FloatingGlass.swift): HUD, island and
   review card all fade in 0.2 s / out 0.18 s with the pill's 8pt rise, 0 under
   Reduce Motion; logical window state stays immediate; a leaving panel is
   inert for its fade. CLAUDE.md bullet added.
7. **Ink on the ground (b)** — receipt and fact strip read one ink; the
   Details panel reads one ink top to bottom. Receipt clock takes tier
   `.speaker` (see the probe note below).
8. **HUD meter idle** — one breathe term (`HUDPillMetrics.breathe`), sampled
   at 15 fps (was 30), constant under Reduce Motion, shared by all three HUD
   styles (bar/prompter never breathed; they now sit ~0.65pt taller at silence).
9. **Copy** — buttons and menu items Title Case (HIG); confirming verbs end
   in `…`; a menu verb names the same thing as its dialog button. Strings:
   Discard → Discard…; Delete Speaker → Delete Speaker…; Delete recording
   audio… → Delete Audio…; Delete record… → Delete Record…;
   Generate/Regenerate/Retry summary → …Summary; Clear search → Clear Search;
   Insert again → Insert Again; Export … "..." → "…"; Change kind → Change
   Kind; menu bar Mark This Moment / Pause Recording / Resume Recording /
   Stop & Summarize. CLAUDE.md quotes updated.
10. **Transitions that cut or leak** — the review card's "Listening…" fades;
    the scroll flag no longer `withAnimation`s the whole document pane; the
    transcript's bottom reserve animates with the receipt's fade.
11. **Tokens + Settings form** — 18 dead tokens deleted; new
    `SettingsForm.swift` (caption / footer / label grammar, window width 720)
    adopted by General/Models/API Keys/Dictation; labels sentence case;
    review-card chrome numbers named (unchanged).
12. **Layout grammar** — one `EmptyStateView` (26pt icon / callout / caption /
    8pt) used by the drawer ×4, Speakers, Dictionary, Usage;
    `CraftTokens.cardCornerRadius` 16 / `cardPadding` 20 (stats strip 12 → 16);
    `CraftSectionLabel` shared by rail + drawer; drawer backdrop
    `accessibilityHidden` + `.isModal`; model ids truncate `.middle`; the
    stale-summary banner wraps to two lines.
13. **Drop + row guards** — a busy drawer row disables only Open and says why
    ("Busy — a transcription is running"); a live or starting session refuses a
    dropped file (`MainPaneDrop.accepts`); home shows the full-bleed drop
    stroke (`DropTargetStroke`, one view for home + pane).
14. **Hit targets + pointer stability** — `Metrics.chipHitTarget` 18 on the
    tag ×, suggestion accept/dismiss, banner ×, drawer pin; the tag × is an
    overlay so the pill is one width hovered or not; home cards and dictation
    rows get hover/press feedback; the status pill carries the whole failure in
    `.help`; "⌘↩ saves · …" caption; menu-bar rows name ⌘K; the Details
    panel's summary slot fades instead of swapping hard.
15. **Dismissal + keyboard** — ⌘L runs the Details panel's dismissal policy
    before opening the drawer (`ChromeDismissal.onToggleDrawer`), one
    `.cancelAction` at a time; Escape closes the Usage sheet and the import
    sheet (the latter asks before discarding a paste); an inline tag / speaker
    name commits on focus loss instead of vanishing (`InlineEditFocusLoss`).
    CLAUDE.md paragraphs added.

Skipped, with reasons in the run log: the toolbar status pill's pop-in
transition still never plays (it lives inside the inserted subtree; making it
play needs the toolbar item restructured — decide whether to drop the
`.transition`); `CraftTokens.warning` was not added (nothing would read it).

## Verification

- Every batch: full `xcodebuild test` in its worktree, 0 failing test cases.
  Most runs `** TEST SUCCEEDED **`; a few printed `** TEST FAILED **` solely
  because a known flaky test crashed or hung and was restarted (see Flakes).
- **Final gate on the merged branch:** Dictation bundle: Executed 588 tests, with 2 tests skipped and 0 failures. UI bundle: Executed 640 tests, with 0 failures (after one restart: the known BackgroundSummaryProcessTests.testTheSummarySubprocessLeavesTheMainActorFree hang, which passes alone in 0.6 s). Zero failing test cases in the whole run; xcodebuild printed TEST FAILED / EXIT 65 only because of that restart. Run 04:53–05:06 PDT on 37-commit branch head fb4429d.
- Not deployed. To try it: merge (or check out) the branch, then
  `npm run deploy:macos`.

## Flakes learned tonight (not regressions)

- `BackgroundSummaryProcessTests` — the whole class, not one test: hangs in
  `Process.waitUntilExit` for a child that already exited (Foundation race);
  passes alone in <1 s. Two different tests in the class hung on different runs.
- `FocusedTargetTests` / `InjectionStrategyTests` — Signal 11 in
  `PasteInjector.capture` or a Main Thread Checker trap in
  `TextInjector.tryAXInject`; live clipboard / AX race (already in memory).
- The gate now runs with `-test-timeouts-enabled YES
  -default-test-execution-time-allowance 360 -maximum-test-execution-time-allowance 600`
  so a hang costs 6 minutes instead of the night. 60/120 is too low: two
  `FieldEngineTests` legitimately take ~180 s each.
- When a bundle restarts after a crash, its "Executed N tests" total drops
  (e.g. dictation 367 vs 588 clean) — tests after the crash point may not run.
  Read the "Restarting after" line, not only the totals.

## Owner notes collected from the implementers (not fixed)

- The receipt's facts are drawn at opacity 0 until `onAppear`, which an
  unhosted `NSHostingView` never fires — pixel probes over `RecordReceiptView`
  measure an empty receipt (`testTheReceiptDrawsNoEmber` passes on the clock).
- `GroundInk` at full alpha trips `RenderProbe.emberPixels`' 0.15 saturation
  floor (warm near-black reads as ember) — why the receipt clock is `.speaker`.
- The review card's own "Listening…" dot is still `accentColor`
  (`DictationReviewPanel`); settings panes' error text is still `.red`.
- `ChipIndicator.color` (`.green/.yellow/.red`) is dead code now;
  `Tokens.emptyIconColorOpacity` is read only by the DebugTuning preview;
  `Metrics.cardCornerRadius` (12) / `cardPadding` (16) are declared but unread.
- Dead-token follow-up: tokens whose twins are retyped in HomeDashboardView /
  HistoryDrawerView / SpeakersSettings / DictionarySettingsView /
  UsageSheetView / SummaryRailView (list in the run log); SpeakersSettings +
  DictionarySettingsView should adopt `SettingsForm`.
- The drawer's remaining ~20 semantic-colour sites are now the odd ones out.
- `SummaryRailView` topic-chip border is still `.secondary.opacity(0.3)`; plain
  `Text` runs with no `foregroundStyle` still fall through to `labelColor`.
- Drawer deletion verbs are now reachable during a file transcription
  (per-record, confirmed). The Transcribe File card keeps its own drop stroke.
- The speaker-suggestion chip is ~5pt taller (18pt buttons in 3pt padding).
- Import sheet: Cancel and Escape are one button, so Cancel also asks when the
  box is non-empty. The rename popover's Return still re-enrols an unchanged
  name.
- The follow flag on the live transcript is view `@State`; nothing on screen
  says "follow paused".
- SF Symbols do not all lay out at one height — a same-grammar geometry test
  must hold the glyph fixed.

## Process notes worth keeping

- `isolation: "worktree"` forks from **master**, not the checked-out branch;
  every implementer had to `git rebase polish/…` first and again before
  reporting. A finished agent's worktree stays locked: `git worktree unlock`
  before `remove`.
- Two lanes on disjoint files worked; SummaryRailView / HistoryDrawerView /
  HomeDashboardView were the hot files and set the ordering.

## How to review in the morning

```
git log --oneline master..polish/overnight-2026-09-02
git diff --stat master..polish/overnight-2026-09-02
git diff master..polish/overnight-2026-09-02 -- CLAUDE.md
```
Then `git checkout polish/overnight-2026-09-02 && npm run deploy:macos` to
look at it, and `git merge --ff-only polish/overnight-2026-09-02` from master
if it holds up. Nothing is pushed.
