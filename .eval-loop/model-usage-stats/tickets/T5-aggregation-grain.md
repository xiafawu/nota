<!-- wayfinder:grilling -->
# T5 — Aggregation grain for the stats view

status: closed
blocked-by: T4 (closed)

## Question

What does the stats view actually aggregate and show?

- **Grain:** lifetime per-model totals? per-run breakdown? time-windowed (last 7/30 days, this month)?
- **Rollup key:** per model id, per provider, per task (transcription vs summary), or all three levels?
- **Metrics per row:** run count, total tokens (in/out), total $, avg $/run?
- **Sort/primary metric:** cost-first or usage-first?
- How estimated-vs-actual rows are distinguished in the totals (from T4's `estimated` flag).

Deliverable: the aggregation contract the home-page panel (T6) and any CLI (T3) render from. Resolve via `/grilling`. Blocked until T4 fixes the stored record shape.

## Resolution

**Two views** (grain = B+C):

1. **Per-model summary** (primary; answers "how much has each model used"):
   - Rollup key: **per `modelId`**, one row each. Sort **cost desc** (most expensive first).
   - Columns: `model · provider · runs · calls · tokensIn · tokensOut · $`.
   - **Windowed**: all-time / last 30d / this-month toggle (filter on record `createdAt`; no schema change — data supports it).
2. **Per-run cost log**: one row per run, its models' summed cost — "what did that meeting cost." A log, not a rollup.

**Estimated / unknown display** (from T4 flags):
- `estimated: true` rows marked with a `~` prefix on the value.
- Unknown summary cost (`costUSD: null`) shows `—`, never `$0`, and is **excluded from the summed total**, with an "N runs have unknown cost" footnote so totals never silently understate.

Rollup by provider or task deferred — a per-model list with a `provider` column carries that info without nesting; transcription-vs-summary is already visible via which models appear. Feeds T6 (two panels to design) and T3 (CLI renders the same per-model contract).
