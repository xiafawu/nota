<!-- wayfinder:grilling -->
# G1 — Refresh + fallback UX

status: closed
blocked-by: none (frontier)

## Question

Where and how does the weekly refresh surface to the user?

- Trigger points: CLI launch, macOS app launch, both? Background task or blocking
  first paint of Settings pickers?
- Manual refresh affordance: "Check for new models" button in Settings → Models?
  A `nota models refresh` verb? Neither?
- Warning surfaces for the zombie fallback (locked rule 4): stderr line for CLI —
  what in the macOS app (Settings banner, one-time alert, silent)?
- **Default-change migration** (from map fog): existing users with no summary
  setting silently move gpt-5-mini → deepseek-v4-flash and now need
  DEEPSEEK_API_KEY. First run without that key: hard error, or warn + fall back
  to an available-key model? Does onboarding/API-Keys tab need copy changes?
- Staleness disclosure: show "models as of <date>" anywhere (Settings footer,
  `nota models` output)?

## Resolution

Grilled 2026-07-21, five decisions:

1. **Trigger = both CLI and app.** Each checks cache age at startup; >7 days →
   background fetch, non-blocking. Atomic write (temp+rename, already required
   by R1 trust rules) handles concurrent fetch; last-writer-wins is safe since
   both write the same filtered content.
2. **Manual refresh = both affordances.** "Check for new models" button in
   Settings → Models (spinner + inline result) AND `nota models refresh` CLI
   verb (forces fetch, prints added/removed ids to stdout).
3. **Zombie warning = stderr + Settings banner.** CLI: one stderr line per run
   ("model X no longer available, using <default>"). App: dismissible banner in
   Settings → Models until the stale setting is changed/unset. Never modal.
4. **Default-key migration = key-aware default resolution.** Default chain:
   deepseek-v4-flash if DEEPSEEK_API_KEY resolves → else OpenAI mini-tier
   (OPENAI_API_KEY) → else Gemini flash (GEMINI_API_KEY); first provider whose
   key resolves wins. One stderr/banner note suggests adding DEEPSEEK_API_KEY
   for the cheaper default. Nobody hard-breaks on upgrade.
5. **Staleness disclosure = footers on both surfaces.** Settings → Models tab
   footer + `nota usage` output footer: "model catalog as of <fetchedAt>".
   Satisfies T1's rates-as-of decision from the usage-stats map.
