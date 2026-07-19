<!-- wayfinder:task -->
# E4 — Assemble the enrichment spec

status: open
blocked-by: E1, E2, E3

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
