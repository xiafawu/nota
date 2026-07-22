<!-- wayfinder:map -->
# Map: Registry model refresh (self-updating model catalog)

## Destination

The model registry refreshed **in place**: summary models self-update weekly from
models.dev (auto-admitting mainline chat models per allowlist), transcription models
hand-curated and current, zombie ids gone, new defaults live (deepseek-v4-flash /
universal), CLI + macOS both reading one shared catalog cache. Execution is carried
by this map — done when the change is shipped, tested, and deployed.

## Notes

- **Domain:** Nota (`xiafawu/nota`). TS `src/registry.ts` + `src/config.ts` +
  `src/utils/settings.ts`; Swift mirror `macos/Nota/App/ModelRegistry.swift`.
- **Tracker:** local markdown (same convention as prior efforts).
- **Execution override:** unlike prior maps, this one *does* — X-tickets ship code.
- **Locked at charting (2026-07-21):**
  1. **Architecture = runtime weekly refresh.** App/CLI checks cache age on launch;
     >7 days → background fetch of `https://models.dev/api.json` → filtered into
     `~/.nota/models-catalog.json`. Baked snapshot fallback; fetch failure never
     blocks a run. Transcription lane (AssemblyAI + OpenAI audio) is NOT in
     models.dev (verified live 2026-07-21: 169 providers, no assemblyai, no
     native openai audio ids) — stays hand-curated in `registry.ts`.
  2. **Refresh may auto-admit** new summary models matching the allowlist into
     pickers. Defaults never move automatically.
  3. **Allowlist = mainline chat only:** OpenAI `gpt-5.x` + `gpt-5.x-mini`
     (exclude codex/pro/chat-latest/realtime), Gemini stable flash + pro
     (exclude preview/image/tts/lite), DeepSeek v4+ flash/pro.
  4. **Zombie policy = hide + warn + fallback:** ids absent from the catalog leave
     pickers; a settings.json referencing one warns and resolves to the default.
     History records keep old ids untouched (display-only).
  5. **Defaults:** summary `deepseek-v4-flash` ($0.14/$0.28 per 1M, 1M ctx),
     transcription `universal` (alias auto-tracks AssemblyAI routing). Amended
     by G1: summary default is a key-aware chain (deepseek → OpenAI mini →
     Gemini flash — first provider whose key resolves).
- **Skills:** `/grilling` for G-tickets; R1 is AFK research against the fetched
  `api.json` (snapshot in scratchpad died with session — refetch).
- One ticket per session; claim via `status: in-progress`.

## Decisions so far

<!-- one line per closed ticket; detail lives in the ticket -->

- [R1 Catalog contract](tickets/R1-catalog-contract.md) — models.dev ids = endpoint ids verbatim (no alias table; Gemini bare-id invariant); predicates admit 8/4/2 models (OpenAI `family` corrupted — use id-regex + modality gate); tiers encoded in `cost.tiers[]` (threshold varies — never hardcode 200k, ignore `context_over_200k`); catalog replaces pricing.ts for summary (unit trap ×1e-6); cache schema v1 + etag/validation/stale-serve rules locked. [Contract](assets/catalog-contract.md).
- [G1 Refresh + fallback UX](tickets/G1-refresh-ux.md) — fetch on both CLI + app startup (>7d, background, atomic write); manual refresh = Settings button AND `nota models refresh` verb; zombie warning = stderr line + dismissible Settings banner; default resolution is key-aware (deepseek → OpenAI mini → Gemini flash, first key that resolves; no hard breaks); "catalog as of <fetchedAt>" footers in Settings Models + `nota usage`.
- [G2 Pricing integration](tickets/G2-pricing-integration.md) — pricing.ts shrinks to transcription-only; summary cost from catalog cache at snapshot (baked snapshot = no-cache fallback); missing cost → costUSD null "unknown" (T5 semantics, no estimation); pricedAsOf = catalog fetchedAt; tiers computed generically from `cost.tiers[]`; ×1e-6 unit conversion with assertion test.

## Not yet specified

- Baked-snapshot refresh ritual (regenerate at release time? manual?) — sharpens
  during X1 implementation.
- AssemblyAI staleness watch (doc-page check ritual vs scheduled agent reading
  their llms.txt) — sharpens after core ships; may become its own tiny effort.
- ~~Comms/UX for existing users whose default silently changes gpt-5-mini →
  deepseek-v4-flash (needs DEEPSEEK_API_KEY they may not have).~~ **Resolved by
  G1:** key-aware default chain (deepseek → OpenAI mini → Gemini flash), warn
  suggests the deepseek key; nobody hard-breaks.

## Out of scope

- Budgets/enforcement, live cost HUD (still reporting-only, per usage-stats map).
- Auto-refresh for transcription models — no machine-readable source exists.
- Changing usage-stats views — only their pricing *source* moves (G2).
- Dictation models — separate subsystem (SpeechAnalyzer, not registry).

## Tickets

| Ticket | Type | Status | Blocked by |
|---|---|---|---|
| [R1 Catalog contract: models.dev shape → Nota schema](tickets/R1-catalog-contract.md) | research | closed | — |
| [G1 Refresh + fallback UX](tickets/G1-refresh-ux.md) | grilling | closed | — |
| [G2 Pricing integration with usage-stats](tickets/G2-pricing-integration.md) | grilling | closed | R1 ✅ |
| [X1 Implement TS: catalog, registry, defaults](tickets/X1-implement-ts.md) | task | open | R1 ✅, G1 ✅, G2 ✅ |
| [X2 Implement macOS: shared cache + dynamic pickers](tickets/X2-implement-macos.md) | task | open | X1 |
| [X3 Ship: docs, deploy, verify](tickets/X3-ship-verify.md) | task | open | X1, X2 |
