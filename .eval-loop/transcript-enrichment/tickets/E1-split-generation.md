<!-- wayfinder:research -->
# E1 — Split-generation contract: prompts, models, cost

status: closed (resolved 2026-07-18)
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

## Resolution

Contract in [E1-contract.md](../assets/E1-contract.md). Key recommendations:
tags/summary-only use the **configured summary model** (decisive argument is API-key
availability, not the ~$0.001 a hardcoded cheap model would save); tags prompt is a
single-line-reply prompt with a **1024 token cap** (reasoning-burn headroom) and a
**throw-on-empty** validation contract; tags-only input ladder — summary text when a
summary exists (~$0.0002), whole transcript when it fits, evenly-sampled ≤50k excerpt
for long un-summarized records (no section+rollup for a one-line answer); usage capture
**reuses `task: "summary"`** via the existing `makeSummaryUsage` (zero schema ripple;
tags spend folds into the model's rollup and the cost card automatically). All three
ops share `callGPT`/`summaryTokenLimit` — no new request plumbing.
