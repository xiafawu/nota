<!-- wayfinder:grilling -->
# G2 — Pricing integration with usage-stats

status: closed
blocked-by: R1 ✅

## Question

Usage-stats (shipped) snapshots `costUSD` at run time from a hand-written
`pricing.ts` table with `pricedAsOf`. The catalog now carries live cost for
summary models. Decide:

- Does `pricing.ts` shrink to transcription-only rates, with summary cost read
  from the catalog cache at snapshot time? Or does the refresh *regenerate*
  `pricing.ts`-equivalent data inside the cache and `pricing.ts` becomes the
  baked fallback?
- `pricedAsOf` semantics when cost comes from the cache: per-run stamp =
  catalog `fetchedAt`?
- Gemini tier branch (≤/>200k) — preserved under whichever source R1 found
  (models.dev tiers vs manual overlay)?
- Models auto-admitted before a Nota release knows them: cost comes from
  catalog — confirm nothing else in usage-stats assumed a closed model set
  (labels, provider derivation for display).

Depends on R1's finding about cost-field fidelity (tiers, cache_read).

## Resolution

Grilled 2026-07-22 (two user decisions; rest settled by R1 facts):

1. **pricing.ts shrinks to transcription-only** (per-duration AssemblyAI +
   OpenAI audio rates — outside models.dev anyway). Summary cost reads from the
   catalog cache at snapshot time; the baked in-repo catalog snapshot is the
   no-cache fallback. One source per lane.
2. **Missing catalog cost at snapshot time → costUSD = null ("unknown")** —
   renders "—", excluded from totals with the existing "N unknown" footnote,
   exactly T5's legacy-row semantics. No estimation from stale rates.

Settled by R1 (engineering, no user call needed):
- `pricedAsOf` for a run = catalog `fetchedAt` at snapshot time.
- Gemini/any tier branch computed generically from `cost.tiers[]` (pick largest
  `thresholdTokens ≤ promptTokens`, else base) — never hardcode 200k; unit
  conversion ×1e-6 (models.dev per-1M vs pricing.ts per-token) with an
  assertion test.
- Auto-admitted models flow through usage-stats untouched: `UsageEntry` already
  stores `{modelId, provider}` per row (open set); labels for display come from
  the catalog entry's `label`.
- `cacheRead` informational only — snapshots use input+output tokens.
