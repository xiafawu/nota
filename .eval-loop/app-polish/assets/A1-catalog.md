# A1 defect catalog — main window (dashboard, document, running)

Audit date: 2026-07-18, deployed build from master `fe0ac0f`, light mode, 780×727 window.
Method: live captures via synthetic CGEvent click/scroll puppetry + `screencapture -l<windowid>`,
plus code audit of `ContentView.swift`, `HomeDashboardView.swift`, `MainPaneView.swift`,
`EmptyMainView.swift`, `ToolbarStatusPill.swift`.

**Privacy note:** screenshots contained personal history titles; they were reviewed live and
deleted, not committed. Entries below carry textual descriptions with file:line evidence instead
of crops. Deviation from ticket's "screenshot crop per entry" — deliberate, sensitivity over
fidelity.

**Not exercised (→ W1 walkthrough):** dark mode, empty-history state, live running view
(code-audited only), narrow-window resize behavior.

Severity scale: **jarring** (breaks the surface) / **noticeable** (reads unpolished) / **nitpick**.

---

## Home dashboard

### H1 · jarring · Scrolled content collides with the transparent title bar
All three views set `.toolbarBackground(.hidden, for: .windowToolbar)`
([ContentView.swift:72,103,135]). On scroll, list content slides under the bar and the window
title "Nota", traffic lights, and the + button sit directly on top of row text — captured with
"Nota" superimposed on the hero card's "Ready to record".
**Violates:** HIG scroll-edge guidance — chrome must stay legible over passing content (macOS 26
scroll edge effect exists precisely for this).
**Fix direction:** keep the borderless look at rest but let the toolbar gain material/blur once
content scrolls beneath (scroll edge effect), or inset content + top fade mask.

### H2 · noticeable · Three card vocabularies on one page
Hero preflight card = white elevated card with shadow; cost card = `.regularMaterial` gray inset
(HomeDashboardView.swift:260); history rows = `.thinMaterial` (line 341). Three surface
treatments with different radii (12 vs 8) on one screen. Raycast/Things use a single consistent
card treatment per surface.
**Fix direction:** one card material + a 2-step radius scale, applied to all three sections.

### H3 · noticeable · History rows: no hover state, not real buttons
Rows are passive views with `onTapGesture` (HomeDashboardView.swift:113–119): no `.onHover`
highlight, no pressed state, no keyboard focus, no accessibility button trait. Every reference
app highlights the row under the pointer.
**Fix direction:** make rows Buttons with a row-highlight style (hover wash + pressed dim);
restores VoiceOver and keyboard operability for free.

### H4 · noticeable · Recent list flattens time
All 22 expanded entries render "1mo ago" — relative-only dates at `caption2` collapse ordering
information; no grouping. Things/Raycast group by recency bands.
**Fix direction:** date group headers (Today / This week / Earlier) or short absolute dates.

### H5 · nitpick · Title truncation uses `.middle`
HistoryDashboardRow (line 313) mid-ellipsizes sentence-shaped titles; `.tail` is the convention
for prose titles (mid is for paths/ids).

### H6 · nitpick · Untitled runs render as bare "Transcript"
Generic title + no tags reads broken next to rich rows. Fallback could be source filename +
date.

### H7 · nitpick · Cost section swaps layout across load states
Loading = bare centered spinner, error = bare text, loaded = material card
(HomeDashboardView.swift:68–90) — card appears/disappears, section height jumps on refresh.
**Fix direction:** fixed-height skeleton inside the same card shell for all three states.

### H8 · nitpick · Empty cost card draws an orphan divider
With zero rows the card still renders headline + divider with nothing beneath until the caption
(lines 198, 247–257).

### H9 · nitpick · Expanded cost table is rigid
Fixed column widths totalling ~490pt (lines 267–292) don't adapt to card width; header
`caption2` vs body `caption` is a subtle mismatch.

## Toolbar / status

### T1 · noticeable · Status pill duplicates content and reads as a control
Center `ToolbarStatusPill` (liquid-glass capsule) persists in document view showing the document
title/status — duplicating the H1 directly beneath it — and in running view shows the same
phase string as the content subtitle (two copies on one screen). Its bordered capsule reads
clickable but ignores clicks.
**Fix direction:** reserve the pill for transient run status only; hide it in completed
document view (or restyle as plain window subtitle, no capsule).

## Document view

### D1 · noticeable · Pinned header eats ~25% of the window and hard-clips scroll
`DocumentHeaderView` + `Divider` are pinned above `RichTextViewer` (MainPaneView.swift:24–30);
transcript text clips mid-line against the hairline with no fade/material edge, and the header
(title, date, chips, tags) never collapses while reading.
**Fix direction:** header scrolls away with content, collapsing into a toolbar title/subtitle
(large-title pattern), or at minimum a scroll-edge fade + compressed header on scroll.

### D2 · noticeable · Speaker chip leaks internal rename mapping
Chip renders "Speaker 1 → Kenny Kim" — the diarization label and the arrow are implementation
detail; a reader wants "Kenny Kim".
**Fix direction:** chip shows the final name; the mapping lives in the rename popover/tooltip.

### D3 · nitpick · Speaker colors carry no information
Both speaker chips use the same yellow dot, and the transcript body never uses speaker colors —
bold names only. Either differentiate hues and echo them in the transcript, or drop the dots.

### D4 · nitpick · Header and body left edges misaligned
H1 sits at ~48pt from window edge; body text at ~53pt (separate containers with different
padding). One content column, one leading edge.

## Running view (code audit only)

### R1 · noticeable · Indeterminate bar for a staged pipeline
EmptyMainView running state shows a pulsing waveform + indeterminate linear ProgressView
(EmptyMainView.swift:31–36) while the pipeline has known ordered stages (validate → transcribe →
summarize → write). No sense of progression; phase-text changes are unanimated; phase also
duplicated in the toolbar pill (see T1).
**Fix direction:** stepped/determinate stage progress with animated phase transitions.

### R2 · nitpick · Window stays titled "Nota" during a run
Filename in the title (or subtitle) would anchor what's being processed.

## Anomaly (unverified, → W1)

One back-button click appeared to close/order-out the window entirely (CGWindowList showed no
Nota window; `open -a Nota` restored it with identical id/frame and prior state). Not
reproduced on retry — flag for the walkthrough: watch whether toolbar back ever closes the
window.
