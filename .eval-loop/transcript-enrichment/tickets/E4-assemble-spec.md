<!-- wayfinder:task -->
# E4 — Assemble the enrichment spec

status: closed (resolved 2026-07-18)
blocked-by: E1, E2, E3 (all closed)

## Question

Fold E1's generation contract, E2's prototype reactions, and E3's storage contract into
`ENRICHMENT-SPEC.md` (polish-spec shape): file-fenced lanes (TS pipeline + CLI verbs vs
Swift document view/model), hard constraints (edited-is-protected; generate-verbs-only
CLI; no transcript editing; empty LLM content = failure), per-lane verification (vitest
+ build:macos + both Swift bundles + screenshot pass for the UI lane), and merge order.

Also sweep the map's fog: dashboard surfacing of un-summarized records (from E2),
usage-task labeling (from E1/E3) — fold resolved items in, graduate anything still open
into tickets instead of shipping an incomplete spec.

Resolving this ticket completes the map; implementation launches from the committed
spec (worktree lanes read committed HEAD — commit the spec before dispatch).

## Resolution

Spec assembled at [ENRICHMENT-SPEC.md](../ENRICHMENT-SPEC.md): two file-fenced lanes
(TS pipeline/history/CLI provides a verbatim CLI contract; Swift document
view/dashboard consumes it blind, mocking the process layer), hard constraints from
the three contracts, and one assembly-scope decision made here: Swift persists through
a **hidden plumbing verb** (`nota history apply-enrichment --json`) so markdown
rendering and record-first atomicity stay in exactly one place — compatible with the
"generate verbs only" user-facing lock. Merge order TS → SWIFT. No remaining fog.
**Map complete.**
