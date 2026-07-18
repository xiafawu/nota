<!-- wayfinder:research -->
# A3 — Audit: dictation HUD live states

status: closed (resolved 2026-07-18)
blocked-by: none (frontier)

## Question

How well does the dark-capsule HUD (`macos/Nota/Dictation/DictationHUDPanel.swift`,
PR #62) execute across ALL its live states — listening (level meter), processing,
success, warning, error — and their transitions, judged against Wispr Flow and the
macOS system dictation indicator?

The dark-capsule *direction* is a locked user decision — audit execution only:
state-to-state resize/crossfade quality, meter motion at low/high levels, tint
legibility for warning/error, positioning relative to the frontmost window, show/hide
animation, behavior over light vs dark desktops and during window drag.

Method: synthetic-fn capture technique from memory `liquid-glass-floating-panel-trap`
(CGEvent fn keypress to start real dictation, `CGWindowListCopyWindowInfo` to find the
panel, `screencapture -R` its bounds); drive non-listening states via real flows or a
debug hook if one exists — do not screenshot mockups.

Deliverable: `assets/A3-catalog.md`, same entry shape as A1.

## Resolution

12 defects in [A3-catalog.md](../assets/A3-catalog.md): 0 jarring, 6 noticeable, 6
nitpicks. Clusters: positioning (anchors to Nota's own windows instead of the dictation
target app; repositions on every 15fps tick with unanimated origin snaps), level meter
(linear ×3 RMS underdrives speech; no time phase so bars freeze at steady input), and
state lifecycle (stale success/warning fields resurrect the HUD on unrelated controller
ticks; 1s success auto-hide unreadable against a 40-char snippet).

Deviation from ticket method: live driving vetoed — no Nota window on the active Space,
and synthetic fn would start a real mic capture / possible injection into the user's
focused app. Evidence = code + PR #62's verified live captures (same commit as
deployed). Five items tagged → W1 for eyes-on verification (stale-state resurrect, dark-
on-dark separation, warning-vs-error tint, two-line capsule shape, plus the general
live-feel pass).
