<!-- wayfinder:task -->
# X2 — Implement macOS: shared cache + dynamic pickers

status: closed
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

## Resolution

Merged to master 2026-07-23 (`052d3d6..6a0f7c9` macOS + cherry-picked
`87c3753`/`8f3dd58` TS fixes). Claude-direct: Opus implementer in isolated
worktree (stale-base rebase per `workflow-worktree-stale-base` memory) + Opus
adversarial reviewer + orchestrator screenshot verification.

- macOS: `ModelCatalog.swift` (Codable reader, baked 14-id fallback verbatim-
  matching the TS `BAKED_SNAPSHOT`), `ModelCatalogModel.swift` (@MainActor
  store; shells `nota models refresh`, 120s watchdog, merged-pipe read,
  fail-fast when CLI missing), dynamic Models-tab pickers + "catalog as of"
  footer + "Check for New Models" + dismissible zombie banner; slam-1/nano
  removed; key-aware default chain mirrored. 11 hermetic catalog tests.
- Review (BLOCKED → fixed in `6a0f7c9`): CRITICAL — picker onChange fired on
  programmatic re-sync and silently persisted the chain default over a stored
  pin after background refresh; persist() now skips values equal to the
  current effective model. Plus refresh-hang watchdog, CLI fail-fast,
  unparseable-fetchedAt-is-stale, offline feedback, banner-dismiss survives
  no-op refreshes.
- **Screenshot verification caught 4 X1 live-fetch bugs** the green suite
  missed (first real refresh wrote 13 models, zero Gemini, id-only labels):
  audio-input gate wiping multimodal Gemini; gpt-4/-4.1/-4.1-mini admitted by
  the generalized regex (floored at gen 5); `entry.label` vs models.dev's
  `name`; 304-etag re-blessing a stale-filtered cache (fixed with a
  `filterVersion` stamp) + per-provider non-empty fetch guard + hermetic
  vitest `NOTA_CATALOG_PATH` setup (suite had been reading the developer's
  real cache).
- Verified live: Models tab shows proper labels, real fetchedAt footer;
  `models refresh` printed `+4 gemini / −3 gpt-4*` repairing the cache.
- Carried to X3: shipped-app CLI distribution (refresh requires the repo
  checkout at NOTA_PROJECT_DIR — pre-existing app-wide convention).
