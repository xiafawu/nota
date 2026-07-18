# W1 walkthrough catalog — user-reported feel gaps

Collection started 2026-07-18. Entries are user-reported during live use, root-caused
against code by Claude. Same severity scale as A1–A4.

---

## W1-1 · noticeable · No transition when opening a transcription (user-reported)
Clicking a history row hard-cuts from dashboard to document view — no animation.
**Root cause:** the home ↔ document swap happens at the TOP of the view tree
(`ContentView.body` switches `homeView` / `documentView` wholesale,
ContentView.swift:26–34) with no `.transition` or `.animation` at that level. The
transition machinery that exists (`.animation(Tokens.animFast, value: isRichContent)`,
MainPaneView.swift:41) lives INSIDE MainPaneView — but home is `HomeDashboardView`, not
`MainPaneView`, so the swap bypasses it entirely.
**Fix direction:** animate at the swap site — e.g. `.transition(.opacity)` (or
asymmetric push: content slides up 8pt + fade, matching HUD show motion) on the
top-level branch, with `withAnimation` in `model.openHistory` / `newTranscription`.

## W1-2 · jarring · Speakers tab corrupts the settings chrome (user-reported, screenshot)
Selecting the Speakers tab (a) injects "+" and "⟳" into the settings toolbar styled like
two extra tabs, and (b) shows a full-height sidebar whose material runs up behind the
tab strip and traffic lights, colliding with the chrome.
**Root cause (a):** `SpeakersSettingsView` declares window-toolbar items
(`.toolbar { ToolbarItemGroup(placement: .automatic) … }`, SpeakersSettings.swift:170–187)
— inside a Settings-scene TabView the tab strip IS the toolbar, so the buttons merge
into it and read as tabs. One of them ("New") is A2-S5's permanently-disabled button.
**Root cause (b):** the tab body is a custom `HStack` with `List(...).listStyle(.sidebar)`
(SpeakersSettings.swift:162–169, 222) — sidebar styling brings full-height source-list
material intended for NavigationSplitView, which visually extends under the settings
window's unified toolbar.
**Fix direction:** remove the toolbar items (fold Refresh into the pane; drop the dead
"New" per A2-S5); use `.listStyle(.inset)` (or `.bordered`) for an in-tab master list so
the tab strip keeps sole ownership of the toolbar region.

<!-- Walkthrough continues — remaining audit watch list:
  A1: dark mode, empty-history state, live running view, narrow-window resize,
      back-click-closes-window anomaly
  A2: live visuals of General/Models/API Keys tabs
  A3: stale-HUD resurrect (toggle a setting after a polish warning), dark pill over
      dark wallpaper, warning-vs-error tint, two-line capsule shape
  A4: popover visuals per state
-->
