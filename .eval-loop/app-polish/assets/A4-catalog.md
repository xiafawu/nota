# A4 defect catalog — menu bar + onboarding/permissions

Audit date: 2026-07-18, code at master `fe0ac0f` (= deployed build).
Method: code audit of `DictationMenuBarView.swift` (status label, popover, onboarding),
`PermissionsCoordinator.swift`, `DictationTypes.swift` (state → title/symbol map),
`NotaApp.swift` (MenuBarExtra scene). Live menu capture skipped — opening the status menu
requires a synthetic click on the user's active Space (vetoed per Space-safety gate), and
the status-item window is not enumerable via CGWindowList (only app-menu cache windows
are). The menu-bar *text* rendering is confirmed live from the prior session's
stuck-at-"Stopping" user screenshot. TCC states were NOT manipulated (ad-hoc TCC trap).

**What's already right:** permission rows carry proper accessibility (combined elements,
hidden decorative icons); each "Open Settings" deep-links the exact Privacy pane;
microphone request handles notDetermined vs denied correctly; menu reopen auto-refreshes
permission state (`onAppear → start() → permissions.refresh()`).

Severity: **jarring** / **noticeable** / **nitpick**.

---

## Menu bar item

### B1 · jarring · Full text label permanently occupies the menu bar
The MenuBarExtra label renders icon + `"Nota Dictation — \(statusTitle)"`
(DictationMenuBarView.swift:8–9) — "Nota Dictation — Idle" sits in the menu bar at all
times (~150pt). Confirmed live (prior session's "Stopping" screenshot). HIG and every
reference utility (Raycast, Wispr, macOS dictation) use icon-only status items; state
belongs in the symbol and the popover.
**Fix direction:** icon-only label (symbol already varies per state); keep the full text
as the accessibility label it already has.

### B2 · nitpick · State wording reads internal
"Stopping" for finalizing (the user read a stuck session as shutdown), "Injecting"
(pipeline jargon; "Inserting…"), "Unavailable" for failed (says nothing actionable)
(DictationTypes.swift:14–28).

### B3 · nitpick · Transient-state symbols
`hourglass` for finalizing and `arrow.down.circle` for injecting are semantically loose;
a progress-flavored symbol family (`ellipsis.circle`, `text.insert`) would read cleaner.

## Menu popover

### B4 · noticeable · No Settings (or About) entry in the status menu
Popover offers only Open Nota / Quit (DictationMenuBarView.swift:43–53). For a menu-bar
agent the status menu is the ONLY chrome when no window is open — dictation settings
(engine, trigger, polish) are unreachable without first opening the main window and
pressing Cmd+, . A2's own UI copy points users at "Settings → API Keys".
**Fix direction:** add "Settings…" (openSettings action) and optionally "About Nota".

### B5 · noticeable · Action buttons don't read as menu rows
Window-style popover uses default-styled `Button`s — no full-width hover highlight, no
row affordance; Open Nota/Quit read as inline links in a form. Reference window-style
extras style them as hoverable rows.
**Fix direction:** full-width row button style with hover wash.

### B6 · noticeable · Debug telemetry in the user menu
"Latency: 0.34s" caption shown while idle (DictationMenuBarView.swift:94–98) — developer
metric in a user surface (same family as A2's embedding-dims finding).

### B7 · nitpick · "Last:" snippet is unbounded
`lastProcessedText` renders in full with vertical `fixedSize` (87–92) — a long dictation
stretches the whole popover. Cap at 2 lines with tail truncation.

### B8 · nitpick · Duplicate disabled messaging
When permissions are missing, both the `.disabled(reason)` text (28–33) and the
onboarding's own explanation render — two paragraphs saying the same thing.

### B9 · nitpick · Quit dressed with a power icon
`Label("Quit Nota", systemImage: "power")` — melodramatic for a routine command; plain
text matches convention.

### B10 · nitpick · Dead code: `diagnosticsSummary`
Defined (131–134) but never called — remove or wire it behind a debug flag.

## Onboarding / permissions

### B11 · noticeable · Distribution jargon in onboarding copy
"Keystroke-by-keystroke injection requires a Developer ID signed, notarized
direct-download build." (170–173) — meaningless and mildly alarming to an end user mid-
permission-grant. Belongs in docs/release notes; the user-facing sentence is "some apps
receive text via paste".

### B12 · nitpick · "Refresh Permissions" button is 90% redundant
Reopening the menu already refreshes (start() → permissions.refresh(),
DictationController.swift:115); the button only helps while the popover stays open after
granting.
**Fix direction:** poll on a short timer while onboarding is visible; drop the button.

### B13 · nitpick · Grant links could name their action
Three identical "Open Settings" link buttons; "Grant in System Settings…" (or per-pane
naming) reads clearer at a glance.
