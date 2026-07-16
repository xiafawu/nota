<!-- wayfinder:grilling -->
# T3 — CLI scope: macOS-only or `nota usage` too

status: closed
blocked-by: none (frontier)

## Question

The stated surface is the macOS home page. Does the usage/cost stats feature also get a CLI surface?

- **macOS-only** — stats panel on `PreflightHomeView`; CLI unchanged. Simplest; consistent with dictation being app-only.
- **CLI too** — add `nota usage` / `nota stats` reading the same history store, tab-separated for scripting (matches existing `nota settings list` / `nota speakers list` conventions).

Since usage data lives in the shared `~/.nota/history` store (written by the TS pipeline), a CLI reader is cheap and the pipeline is where costs are actually incurred — unlike dictation, this feature's data is CLI-native. Decide whether that cheap CLI surface is in-scope for the spec or deferred.

Resolve via `/grilling`.

## Resolution

**CLI too.** Add `nota usage` rendering the T5 aggregation contract: per-model
summary (default) + per-run log (subcommand or flag), window filter
(`--window 30d|month|all`). Output conventions match `nota settings list` /
`nota speakers list`: tab-separated rows on stdout, header/confirmations on
stderr, scriptable. Rationale: the cost-incurring pipeline is CLI-native, the
aggregators (`src/usage-stats.ts`, merged in PR #45) are already pure TS —
the command is a thin renderer; gives usage visibility before the macOS panel
ships. Estimated values `~`-prefixed; unknown costs render `—` and a trailing
"N runs have unknown cost" note on stderr.
