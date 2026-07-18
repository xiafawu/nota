<!-- wayfinder:research -->
# A1 — Audit: main window (dashboard, document, running)

status: open
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
