<!-- wayfinder:task -->
# W1 — User walkthrough: feel gaps (HITL)

status: closed (resolved 2026-07-18)
blocked-by: A1, A2, A3, A4 (all closed)

## Question

Which polish defects do the screenshot audits miss — motion feel, latency,
interaction friction, anything that only shows up in live use?

HITL task: the user drives the deployed app end-to-end (transcribe a file via share
handler, dictate with fn in a real editor, browse history, change a setting) and
narrates annoyances; Claude catalogs them in the same entry shape as the audit
catalogs (defect, where, severity — screenshots where reproducible). The four audit
catalogs are read FIRST so the walkthrough targets what static capture can't see,
not what's already filed.

Deliverable: `assets/W1-catalog.md`, appended to the combined defect pool for D1.

## Resolution

2 user-reported defects in [W1-catalog.md](../assets/W1-catalog.md), both root-caused:
W1-1 (noticeable) missing home→document transition — swap happens above the view that
owns the animation; W1-2 (jarring) Speakers tab corrupts settings chrome — window-toolbar
items merge into the tab strip + sidebar list material runs under it. Confirms and
upgrades A2-S5.

User closed the walkthrough without exercising the audit watch list (dark mode, HUD
resurrect, dark-pill separation, warning/error tint, General/Models/API-Keys visuals,
back-click anomaly) — those A-catalog findings enter D1 as code-confirmed but visually
unverified; any fix touching them verifies visually during implementation instead.
Combined defect pool for D1: 57 findings (A1 17, A2 13, A3 12, A4 13, W1 2).
