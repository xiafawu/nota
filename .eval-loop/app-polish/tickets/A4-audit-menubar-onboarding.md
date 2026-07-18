<!-- wayfinder:research -->
# A4 — Audit: menu bar + onboarding/permissions

status: open
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
