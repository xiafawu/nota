<!-- wayfinder:task -->
# X1 — Implement TS: catalog, registry, defaults

status: closed
blocked-by: R1 ✅, G1 ✅, G2 ✅

## Question

Ship the TypeScript side per the locked decisions + R1/G1/G2 contracts:

- Catalog module: fetch (7-day age check, background, never blocks), validate
  (R1 trust rules), write `~/.nota/models-catalog.json`; baked snapshot in-repo
  as fallback.
- `registry.ts`: static transcription entries stay; summary entries resolve from
  catalog cache (allowlist predicates from R1); zombie handling = hide + warn +
  fallback (rule 4) in `config.ts`/`settings.ts` validation.
- Defaults: summary `deepseek-v4-flash`, transcription `universal`; key
  requirement derivation follows (DEEPSEEK_API_KEY for fresh installs), G1's
  first-run behavior.
- Pricing wiring per G2.
- Tests: catalog filter fixtures (vendored api.json snippet), zombie fallback,
  default resolution, offline/corrupt-cache paths. Update CLAUDE.md + README
  valid-id language (ids are now dynamic — describe the rule, not the list).

Resolution records commits + test counts.

## Resolution

Implemented by omp (HANDOFF-X1-CATALOG.md), verified through all six ingest
gates, merged ff to master 2026-07-22 (`11c6666..693f37b`).

- Commits: `d22e277` (L1 catalog module), `9ef297f` (L2 registry/config),
  `5ed3f3c` (L3 pricing), `7aa9032` (L4 CLI verbs + TTL + footer), `c60589b`
  (L5 CLAUDE.md), `693f37b` (review fix: dead baked-json duplicate removed).
- Gates: 402 tests green locally; tsc clean; `models list` works offline from
  baked snapshot (14 ids, google→gemini mapped, exit 0); ×1e-6 conversion +
  $0.0045 assertion verified in code; 272k non-200k tier test present;
  `thresholdTokens` read from `tier.size`, never hardcoded; zombie
  warn-and-fallback real; `slam-1`/`nano` removed; no `macos/**` touched.
- Deviations (undeclared by omp, adjudicated on ingest): named chain/zombie
  test files consolidated into `tests/config.test.ts` (content present —
  accepted); `src/models-catalog.baked.json` was dead (snapshot is inlined as
  `BAKED_SNAPSHOT` in `src/catalog.ts:419`) — removed in `693f37b`. Handoff's
  README.md item was vacuous (no README exists).
- Fog note for X3: baked-snapshot regeneration ritual = re-run the allowlist
  against a fresh api.json and update the `BAKED_SNAPSHOT` literal in
  `src/catalog.ts` (no separate file).
