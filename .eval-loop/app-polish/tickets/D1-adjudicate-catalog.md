<!-- wayfinder:grilling -->
# D1 — Adjudicate the combined defect catalog (HITL)

status: closed (resolved 2026-07-18)
blocked-by: W1 (closed)

## Question

For every entry in the combined catalog (A1–A4 + W1): fix it, fix it differently
than proposed, or won't-fix? And in what priority order do the surfaces ship?

Grilling session, one defect-cluster at a time (cluster by surface, lead with the
audit's recommended direction). Structure-level findings get explicit yes/no — a
view merge/split needs the user's word, never just the audit's. Output per entry:
verdict + agreed fix direction + severity-derived priority.

If verdicts reveal a cross-surface question (shared tokens, motion standards, IA
change), graduate it from the map's fog into its own ticket rather than resolving
it inline.

Deliverable: verdict table in this ticket's resolution; feeds S1 directly.

## Resolution

Adjudicated 2026-07-18 in nine clusters; user verdicts:

| Cluster | Findings | Verdict |
|---|---|---|
| 1 Chrome & transitions | A1-H1, W1-2, W1-1, A1-T1 | **Fix all 4** |
| 2 Menu bar | B1, B4, B5, B6 + B2, B3, B7, B8, B9, B10 | **Fix all incl. nitpicks** |
| 3 Dashboard | H2, H3, H4 + H5–H9 (6 nitpicks) | **Fix all incl. nitpicks** |
| 4 Document view | D1, D2, D3, D4 | **Fix all 4** |
| 5 Running view | R1 (staged progress), R2 | **Fix both** |
| 6 HUD | P1, P2, M1, M2, L1, L2 + V1–V3, A1(a11y), P3, L3 | **Fix all; nitpicks verified during implementation, fixed if confirmed** |
| 7 Settings structure | S1, S2, S12 | **Fix all 3** |
| 8 API Keys + Speakers | S3, S4, S11, S5, S6, S9, S13 | **Fix all** |
| 9 Copy & tone | S7, S10, B11, B12, B13 | **Fix all** — **S8 (key-capture recorder) deferred: won't-fix this effort** |

Net: 56 of 57 findings accepted for fix; S8 alone deferred (real widget work, not
polish). Structure-level items approved explicitly via cluster verdicts (D1 header
collapse, S2 per-tab height, S4 API-Keys row restructure, W1-2 Speakers layout).

**Shipping order (user-chosen):** Chrome → Dashboard → HUD → Settings → Menu bar —
most-jarring first, one worktree branch + PR per surface, screenshot-verified before the
next lands. Running-view and document-view fixes ride in the Chrome/Dashboard PRs where
their files overlap (ContentView/MainPaneView).
