# PI/omp Handoff — T6: dashboard home (usage panel + sidebar removal)

Self-contained. Assume no prior conversation. Repo: `/Users/xiafawu/Developer/Nota`.
Branch off **master** (green at `f4e457a` or later). One reviewable PR.
No other feature branches in flight.

## Context

Nota's macOS app is no longer transcription-only (dictation shipped). The
window still uses a `NavigationSplitView` whose sidebar is a history list —
that layout dies. The home (detail pane when no document open) is
`PreflightHomeView`, a traffic-light health dashboard. Usage/cost data layer +
`nota usage` CLI are merged (`src/usage-stats.ts` aggregators, T5 display
contract: `~` = estimated, `—`/footnote = unknown, never $0 for unknown).

## Locked decisions (grilled 2026-07-16; not re-openable)

1. **Single-pane dashboard home** — remove `NavigationSplitView`/sidebar from
   `ContentView.swift`. Home = one scroll: health section (existing preflight,
   reuse `PreflightHomeView` internals), usage cost card, Recent history.
   "New Transcription" moves to the window toolbar. Opening a document swaps
   the full pane to the document view with a Back-to-home toolbar affordance.
2. **Cost card** — headline: windowed total spend (`~` prefix when any
   estimated contribution). Below: top 5 models by cost (label · runs · $).
   Footnote "N runs unknown cost" when present. "See all" expands inline to
   the full per-model table (adds provider/calls/tokensIn/tokensOut columns).
   No per-run log in the app (CLI has it).
3. **Data path: `nota usage --json`** — new flag on the existing CLI command
   printing `{ "window": "...", "rows": ModelSummaryRow[] }` to stdout
   (single JSON doc, no TSV). Swift shells out (same mechanism the app
   already uses to run transcriptions) and decodes. NO aggregation logic in
   Swift — the TS aggregators stay the single source of semantics.
4. **Recent history** — ~6 rows (title · relative date · tags; click opens,
   context-menu Reveal, same actions as today's `HistoryPaneView` rows) +
   "Show all" expanding inline to the full scrollable list.
5. **Window picker** — segmented "30d / All" on the card, default 30d,
   persisted via `UserDefaults` (Swift-only key, NOT `~/.nota/settings.json`).
6. **Empty states** — no history: "No usage yet — costs appear after your
   first transcription". All-unknown costs: `—` total + unknown footnote
   (mirror CLI; never render $0.00 for unknown).

## Hard constraints

- `src/**` changes limited to EXACTLY: `src/cli/usage.ts` (add `--json`
  serialization of existing aggregator output), `src/index.ts` (flag wiring),
  `tests/cli/usage.test.ts` (new tests). Do NOT touch `src/usage-stats.ts`
  logic, `src/pricing.ts`, registry, history schema, or any pipeline file.
- Swift: do not break document open/render flow, dictation (menu bar, HUD,
  settings), or the preflight checks themselves — this is a re-layout, not a
  rewrite of those features. `HistoryPaneView` row affordances may be reused/
  adapted; the file may be renamed/absorbed.
- No new TCC permissions, no signing/deploy changes, no `~/.nota/settings.json`
  writes.

## Task + lane manifest (two lanes)

- **Lane A (parallel-safe)** — owns `src/cli/usage.ts`, `src/index.ts`,
  `tests/cli/usage.test.ts` ONLY: `nota usage --json [--window w]`. JSON
  schema: `{"window":"all|30d|month","rows":[{"modelId":...,"provider":...,
  "runs":N,"calls":N,"tokensIn":N,"tokensOut":N,"costUSD":N,"hasUnknown":B,
  "hasEstimated":B}]}` — field names exactly match `ModelSummaryRow`. stdout
  = the JSON only; notes stay on stderr. `--json` with `runs` subcommand is
  out of scope (error or ignore consistently — document which).
- **Lane B (sequential)** — everything Swift: `ContentView` re-layout,
  `HomeDashboardView` (health + cost card + recent), `UsageStatsProvider`
  (spawn CLI `usage --json`, decode, cache per window choice, refresh on
  home appear and after each completed run), toolbar changes, document
  back-navigation.
- Lane B depends on lane A's schema but NOT its merge — the schema above is
  frozen; build against it.

## Stop-fence

T6 ONLY. No per-run log UI, no charts/graphs v1, no history search, no
Settings redesign, no dictation changes.

## Verify (non-negotiable; named tests are part of the fence)

- `npm test` green including NEW `--json` tests: schema shape, window
  filtering, unknown/estimated flags surviving serialization, empty history.
- `npm run build:macos` prints `** BUILD SUCCEEDED **`; `xcodebuild test`
  green including NEW `UsageStatsProviderTests` (JSON decode from fixture
  strings incl. empty/malformed → error state, never crash) and
  `HomeDashboardStateTests` (cost-card view-model: estimated marker, unknown
  footnote, top-5 truncation, empty states).
- Manual on user machine: home renders all three sections; open doc → back;
  New Transcription from toolbar; card numbers match `nota usage` CLI output
  for both windows.

## Required reply

Reply using exactly these sections:

```
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries —
                            npm test tail + build:macos BUILD SUCCEEDED + xcodebuild test tail)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine — live home render, CLI parity check)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
```
