# A3 defect catalog — dictation HUD live states

Audit date: 2026-07-18, code at master `fe0ac0f` (= deployed build).
Method: code audit of `DictationHUDPanel.swift`, `DictationHUDController.swift`,
`DictationHUDState.swift`, `MicCapture.swift` (level source), plus the verified live
captures of the listening state from the PR #62 session (same commit). **Live driving was
vetoed this session:** no Nota window on the active Space — synthetic fn would have
started a real mic capture and possibly injected into the user's focused app. Items
needing eyes-on-screen are tagged **→ W1**.

Scope guard: dark-capsule *direction* is locked; execution only.

**What's already right:** the shadow-box fix (`hasShadow=false` + SwiftUI shadow in a
24pt margin), fade+rise show / fade-out hide, center-weighted 9-bar silhouette,
`.statusBar` level + all-Spaces/fullscreen-auxiliary behavior, click-through panel,
throttled (~15fps) level pipeline, forced-dark scheme for constant legibility.

Severity: **jarring** / **noticeable** / **nitpick**.

---

## Positioning

### P1 · noticeable · HUD anchors to Nota's own windows, not the app being dictated into
`reposition()` keys off `NSApp.keyWindow ?? NSApp.mainWindow` (DictationHUDPanel.swift:67–77)
— those are *Nota's* windows. Dictation targets other apps: with the dashboard open, the
pill appears under Nota's window (possibly another screen) while the user dictates into
Safari; `NSScreen.main` likewise picks Nota's screen on multi-display.
**Fix direction:** anchor to the frontmost app's focused window (AX) or always
bottom-center of the screen containing the active app / cursor — the Wispr placement.

### P2 · noticeable · Reposition fires on every update tick and fights the resize animation
`update()` calls `reposition()` on every controller tick — including ~15fps level updates
(DictationHUDController.swift:66–69) — with an unanimated `setFrameOrigin`, while state
swaps animate the frame (DictationHUDPanel.swift:54–59). Anchor-window moves make the pill
teleport, and an origin snap can land mid-resize-animation (diagonal slide artifact).
**Fix direction:** position once per show (session-pinned like Wispr); reposition only on
screen-parameter changes.

### P3 · nitpick · Shadow margin not subtracted in position math
Window frame includes the 24pt transparent shadow margin, but `reposition()` treats frame
edges as pill edges — intended 12pt gap below a window renders as ~36pt; the bottom-center
fallback (`minY + 60`) sits visually ~84pt up.

## Level meter

### M1 · noticeable · Linear ×3 RMS mapping underdrives conversational speech
`rmsLevel = min(rms * 3.0, 1.0)` (MicCapture.swift:148). Typical speech RMS ~0.05–0.2 →
level 0.15–0.6, so bars hover in the bottom third and rarely peak; whispering barely
registers.
**Fix direction:** dB mapping (e.g. `20·log10`, floor −50dB, normalized) with
fast-attack / slow-release envelope — the standard voice-meter transfer curve.

### M2 · noticeable · Meter freezes between level changes
Bar wobble is a pure function of `(index, level)` (DictationHUDPanel.swift:239) — no time
phase. At steady input (silence, hum) all bars hold still; the meter looks dead during
pauses. Reference meters keep a subtle idle breathing.
**Fix direction:** add a slow time-driven phase term (TimelineView) so bars idle-breathe
at low amplitude.

## State lifecycle

### L1 · noticeable · Stale success/warning resurrects the HUD on unrelated updates
`lastPolishWarning` / `lastSecureFieldNotice` / `lastProcessedText` stay set while idle
(HUDState.compute, DictationHUDState.swift:40–51 — the comment admits "stale until next
session"). Auto-hide hides the panel, but ANY later `objectWillChange` tick recomputes the
same warning/success state and re-shows the pill — a settings toggle after a failed polish
can resummon a 3-second-old warning. **→ W1** to confirm live.
**Fix direction:** clear the underlying fields when the auto-hide fires (hide = consume).

### L2 · noticeable · Success auto-hide (1s) can't be read against a 40-char snippet
SuccessView shows up to 40 chars + quotes (DictationHUDPanel.swift:267–271); auto-hide is
1.0s (DictationHUDController.swift:83–84) — ~8 words in a second. Either extend to ~2s
when a snippet is present, or drop the snippet and show only the checkmark.

### L3 · nitpick · Error persistence equals warning persistence
Fatal errors auto-hide after the same 3s as non-fatal warnings. A mic-permission or
engine failure deserves to linger (or persist until next trigger) so the user can act.

## Appearance (→ W1 visual verification)

### V1 · nitpick · Dark-on-dark separation unverified
Constant dark capsule over a dark desktop: black shadow invisible, separation carried
solely by the 0.5pt white-16% hairline. May blend into dark wallpapers. **→ W1**: check
over a dark screen; if it melts, raise hairline opacity or add a faint outer glow.

### V2 · nitpick · Warning vs error tint may be indistinguishable at a glance
`.red.opacity(0.28)` / `.orange.opacity(0.24)` washes over a 0.9-alpha near-black body
(DictationHUDPanel.swift:176–182) — both read as "dark with a hint of color"; the glyph
alone carries the semantic. **→ W1** eyeball.

### V3 · nitpick · Two-line messages stretch the capsule into a lozenge
Warning/Error text allows 2 lines with vertical `fixedSize` inside a Capsule background —
tall capsule + 18/12 padding may look stretched. **→ W1** with a long secure-field notice.

## Accessibility

### A1 · nitpick · No VoiceOver announcements for state changes
The panel is click-through and never key; state transitions (listening → success/error)
post no `NSAccessibility` announcements, so VO users get no feedback that dictation
started, finished, or failed.
