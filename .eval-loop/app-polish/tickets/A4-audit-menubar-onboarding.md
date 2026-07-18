<!-- wayfinder:research -->
# A4 — Audit: menu bar + onboarding/permissions

status: closed (resolved 2026-07-18)
blocked-by: none (frontier)

## Question

What are the fit-and-finish defects in (a) the menu-bar item — icon states, menu
structure, item wording, dictation status surfacing — and (b) the three-permission
onboarding gate (Microphone, Accessibility, Input Monitoring) — copy clarity,
recovery paths when a grant is missing, re-prompt behavior after the TCC reset trap —
judged against HIG menu-bar-extra conventions and reference utilities (Raycast,
CleanShot)?

Method: screenshot the menu in each app state (idle, transcribing, dictating);
exercise the onboarding gate by inspecting its code paths and, where safely
reachable, its live UI (do NOT revoke real TCC grants to force states — cite the
ad-hoc TCC trap memory instead).

Deliverable: `assets/A4-catalog.md`, same entry shape as A1.

## Resolution

13 defects in [A4-catalog.md](../assets/A4-catalog.md): 1 jarring, 4 noticeable, 8
nitpicks. The jarring one: the MenuBarExtra label renders full text — "Nota Dictation —
Idle" permanently in the menu bar (~150pt); references are icon-only. Noticeable: the
status menu has no Settings… entry (only chrome the agent app has when windowless),
default-styled buttons that don't read as menu rows, "Latency: 0.34s" debug telemetry in
the idle menu, and Developer-ID/notarization jargon inside the onboarding copy.

Deviations: live menu/status-item capture skipped (Space-safety gate + status-item
window not CGWindowList-enumerable); menu-bar text rendering confirmed from the prior
session's live "Stopping" screenshot; TCC grants untouched. Popover visuals in each
state → W1.
