<!-- wayfinder:research -->
# E1 — Split-generation contract: prompts, models, cost

status: open
blocked-by: none (frontier)

## Question

How does the single combined summarize call (`src/pipeline/summarize.ts` — narrative +
key topics + decisions + action items + `### Tags`) split into three invocable
operations — full summary, summary-only refresh, tags-only — and what does each cost?

Cover: (a) prompt drafts for tags-only (input = `transcriptText` from the history
record; output = 3–6 lowercase tags) and for summary-without-tags; (b) whether tags-only
can run on a cheaper model (gpt-5-mini vs deepseek-v4-flash vs the configured summary
model) with estimated per-run cost from `pricing.ts` rates; (c) the >100k-token
section-then-rollup path for tags-only (can it tag from the rolled-up summary instead of
re-reading the whole transcript when a summary exists?); (d) how usage capture records
these calls (`UsageEntry.task` — new label or reuse `"summary"`) and the knock-on for
`nota usage` and the cost card; (e) parse/validation contract (reject empty/malformed
tag lines — remember the reasoning-model empty-content trap: empty LLM content is a
failure, never success).

Deliverable: `assets/E1-contract.md` — prompts, model recommendation with cost table,
API shape for the three operations, usage-capture recommendation.
