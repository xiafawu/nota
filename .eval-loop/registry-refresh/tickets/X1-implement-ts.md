<!-- wayfinder:task -->
# X1 — Implement TS: catalog, registry, defaults

status: in-progress (dispatched to omp — HANDOFF-X1-CATALOG.md)
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
