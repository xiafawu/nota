<!-- wayfinder:prototype -->
# T6 — Home-page stats panel design

status: closed (2026-07-16, PR #59)
blocked-by: T3 ✅, T5 ✅

## Question

How does the usage/cost panel look and sit within `macos/Nota/UI/PreflightHomeView.swift`?

- Placement relative to the existing preflight/traffic-light home content — a card, a section, a tab?
- Per-model rows: what columns (model label, runs, tokens, $), how many shown, overflow behavior.
- Empty state (no history / all-legacy-no-cost data).
- Estimated-vs-actual visual treatment (e.g. "~" prefix or a footnote).
- If T3 put stats in the CLI too, keep the two surfaces consistent in what they report.

Deliverable: a `/prototype` artifact (SwiftUI stub or mock) to react to, linked here. HITL. Blocked until T5 fixes the aggregation contract and T3 fixes whether CLI parity matters.

## Resolution (2026-07-16)

Skipped the mock — grilled the design live (5 decisions) and shipped directly
(HANDOFF-T6-HOME.md, PR #59). Scope grew: user chose to remove the history
sidebar entirely; home became a single-pane dashboard (health + cost card +
recent history). Cost card: 30d/All picker (UserDefaults), headline total with
`~` when estimated, top-5 models by cost, unknown = `—` + footnote (never $0),
inline See-all. CLI parity by construction: Swift decodes `nota usage --json`
(new flag), aggregation semantics stay in `src/usage-stats.ts`. New
`NotaUITests` bundle: HomeDashboardStateTests + UsageStatsProviderTests.
