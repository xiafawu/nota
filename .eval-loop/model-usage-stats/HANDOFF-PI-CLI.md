# PI Handoff — `nota usage` CLI command

Self-contained. Assume no prior conversation. Repo: `/Users/xiafawu/Developer/Nota`.
Branch off **master** (green at `894e9b5` or later). One reviewable PR.

## Context

The usage/cost data layer is merged: history records carry `usage?: UsageEntry[]`
(`src/pipeline/history.ts`), and `src/usage-stats.ts` exposes pure aggregators —
`perModelSummary(records, window?)` → `ModelSummaryRow[]` (sorted cost-desc),
`perRunLog(records)` → `RunLogRow[]`, `AggregateWindow = "all" | "30d" | "month"`.
Records load via `listHistoryRecords()` in `src/pipeline/history.ts`.

Your task: a **thin CLI renderer** over those aggregators. No new computation —
if a number needs deriving, it belongs in `usage-stats.ts`, not the command.

**Lane manifest:** single `sequential` lane — one agent. The task is small and
all files interlock (`src/index.ts` registers what `src/cli/usage.ts` exports);
do not split into an agent team. THIS TASK ONLY — do not start the macOS
home-page panel or any other surface.

## Command surface

Add a `usage` command to `src/index.ts` (commander; follow the existing
`settings`/`speakers` subcommand patterns) with implementation in a new
`src/cli/usage.ts`:

- `nota usage` — per-model summary (default view). One tab-separated row per
  model on **stdout**: `model  provider  runs  calls  tokensIn  tokensOut  costUSD`.
  Human niceties (header line, totals, notes) go to **stderr** so stdout stays
  scriptable — mirror how `nota settings list` and `nota speakers list` split
  stdout/stderr.
- `nota usage runs` — per-run cost log: `id  date  models  costUSD` per row,
  newest first (order as returned by `perRunLog`).
- `--window <all|30d|month>` on both (default `all`); validate and exit
  non-zero listing valid values on a bad window.

## Display rules (locked by design tickets; do not change)

- **Estimated** values (`estimated: true` contributions) are prefixed `~`.
- **Unknown** cost (`costUSD: null`, e.g. legacy records' summary side) renders
  `—`, is **excluded from totals**, and produces a trailing stderr note:
  `N runs have unknown cost`. Never render unknown as `$0`.
- Costs formatted as USD with enough precision for small values (e.g. `$0.0042`);
  token counts as plain integers.
- Empty history / no usage data: friendly stderr message, empty stdout, exit 0.

## Hard constraints

- Do NOT modify `src/usage-stats.ts` aggregation logic, `src/pricing.ts` rates,
  the `UsageEntry` schema, or `src/registry.ts`. Rendering only. (Adding a small
  pure formatting helper to `src/cli/usage.ts` is fine.)
- No macOS/Swift changes — the home-page panel is a separate effort.
- Keep `~/.nota/settings.json` schema untouched.

## Tests

`tests/cli/usage.test.ts` (mirror existing CLI test patterns): default view with
mixed known/estimated/unknown records (assert `~` prefix, `—`, unknown-count
note, exclusion from totals); `runs` view; `--window` filtering + invalid-window
exit code; empty-history case.

## Verify

- `npm run build` clean; `npm test` green (new tests included).
- Manual: `npm run dev -- usage` and `npm run dev -- usage runs --window 30d`
  against real `~/.nota/history` produce sane tables; stdout parseable by `awk`.
- `git status`: only `src/index.ts`, `src/cli/usage.ts`, tests. Update the
  CLI-flags section of `CLAUDE.md` and `README` only if README documents
  commands (check first).

## Required reply

Reply using exactly these sections:

```
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine/data)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
```
