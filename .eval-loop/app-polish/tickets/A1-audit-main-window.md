<!-- wayfinder:research -->
# A1 — Audit: main window (dashboard, document, running)

status: closed (resolved 2026-07-18)
blocked-by: none (frontier)

## Question

What are the fit-and-finish defects in the main window's three states —
`HomeDashboardView` (health/cost/recent), `documentView` (rendered transcript), and
`runningView` (in-flight pipeline) in `macos/Nota/UI/ContentView.swift` — judged
against Apple HIG and the reference set (Raycast, Things, CleanShot)?

Method: run the deployed app, screenshot each state (empty history, populated history,
loading, error where reachable), compare side-by-side with reference apps' equivalent
surfaces. Structure-level findings (sections that should merge/split/move) are in
scope per the map's fence.

Deliverable: `assets/A1-catalog.md` — one entry per defect: screenshot crop, what's
wrong, which reference/HIG rule it violates, proposed fix direction, severity
(jarring / noticeable / nitpick). Recommendations only; no verdicts, no code.

## Resolution

17 defects catalogued in [A1-catalog.md](../assets/A1-catalog.md): 1 jarring, 7 noticeable,
9 nitpicks. Headline finding: `.toolbarBackground(.hidden)` on all three views lets scrolled
content collide with the window title/traffic lights (H1) — the single most damaging polish
defect on the surface. Clusters: card-vocabulary inconsistency (H2), inert history rows
(H3, also an accessibility gap), pinned document header hard-clipping scroll (D1), status
pill duplicating content (T1), indeterminate progress for a staged pipeline (R1).

Deviations from ticket method: screenshots deleted, not committed (personal history titles);
running view + empty state audited from code, not live; dark mode and resize behavior not
exercised — all flagged into W1's watch list, plus one unreproduced back-button
window-close anomaly.
