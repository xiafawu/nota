<!-- wayfinder:task -->
# X3 — Ship: docs, deploy, verify

status: open
blocked-by: X1, X2

## Question

Close out the effort:

- Full gates: `npm test` + `npm run build` + Swift build/tests green.
- Deploy the macOS app; live verification: fresh catalog fetch on stale cache,
  pickers show current lineup, zombie id in a scratch settings.json warns and
  falls back, run with deepseek-v4-flash default completes end-to-end (real
  transcription optional — user's call).
- Docs sweep: CLAUDE.md model sections (valid ids → rules), README, `nota
  settings` help text.
- Update this map: Decisions so far entries, mark complete; note the baked-
  snapshot regeneration ritual decided during X1 (currently fog).

Resolution records deploy evidence + any residual follow-ups.
