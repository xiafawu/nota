<!-- wayfinder:grilling -->
# T3 — CLI scope: macOS-only or `nota usage` too

status: open
blocked-by: none (frontier)

## Question

The stated surface is the macOS home page. Does the usage/cost stats feature also get a CLI surface?

- **macOS-only** — stats panel on `PreflightHomeView`; CLI unchanged. Simplest; consistent with dictation being app-only.
- **CLI too** — add `nota usage` / `nota stats` reading the same history store, tab-separated for scripting (matches existing `nota settings list` / `nota speakers list` conventions).

Since usage data lives in the shared `~/.nota/history` store (written by the TS pipeline), a CLI reader is cheap and the pipeline is where costs are actually incurred — unlike dictation, this feature's data is CLI-native. Decide whether that cheap CLI surface is in-scope for the spec or deferred.

Resolve via `/grilling`.
