<!-- wayfinder:research -->
# A3 — Audit: dictation HUD live states

status: open
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
