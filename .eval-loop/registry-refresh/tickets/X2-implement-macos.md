<!-- wayfinder:task -->
# X2 — Implement macOS: shared cache + dynamic pickers

status: in-progress (Claude-direct, opus subagents)
blocked-by: X1 ✅

## Question

Swift side reads the same catalog:

- `ModelRegistry.swift` hardcoded summary list replaced by reading
  `~/.nota/models-catalog.json` (X1's schema); transcription list stays static.
- Settings → Models pickers populate dynamically; zombie warning surface and
  staleness/"models as of" disclosure per G1; manual refresh affordance per G1.
- Decide in-ticket: does the app trigger its own weekly fetch, or only consume
  the cache the CLI wrote (app runs the pipeline via the CLI — the CLI fetch may
  suffice)? Prefer one fetcher.
- Tests + screenshot verification of the Models tab (macos-vision-ui-review).

Resolution records commits + screenshot evidence.
