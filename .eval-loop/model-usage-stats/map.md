<!-- wayfinder:map -->
# Map: Per-model money/token usage stats

## Destination

A handoff spec (CODEX-SPEC style) that locks every decision for a **per-model money & token usage** feature surfaced on the macOS home page (`PreflightHomeView`): pricing source, what's captured per run, the history storage schema, aggregation grain, CLI scope, and the home-page panel design. Ready to dispatch to an implementing agent — no code shipped by this map.

## Notes

- **Domain:** Nota (`xiafawu/nota`). Swift/macOS app + TS CLI/pipeline.
- **Tracker:** local markdown (Linear writes are blocked by permission rules; 2 stray `wayfinder:grilling`/`wayfinder:prototype` labels were created there before the block — harmless, ignore).
- **Plan, don't do:** each ticket resolves a decision; the map is done when a spec can be assembled. Do NOT build the feature.
- **Locked already:** destination = spec handoff (not execution). Cost authority = **hybrid** — actual token usage where the API returns it (OpenAI/Gemini), duration×rate for AssemblyAI, estimation only as fallback for legacy/token-less providers.
- **Skills per ticket:** `/grilling` + `/domain-modeling` (decisions), `/prototype` (T6), read provider docs (research tickets). One ticket per session; claim by marking `status: in-progress`.
- **Ground truth:** registry has no pricing today; history stores `durationMinutes` only — no tokens, no cost, no per-model attribution. Feature needs capture + storage, not just a view.

## Decisions so far

<!-- one line per closed ticket; detail lives in the ticket -->
- [T2 Per-call usage capture](tickets/T2-usage-capture.md) — All three providers expose usage data in API responses, none captured today. Tokens: Chat Completions `response.usage`. Duration: Whisper `TranscriptionVerbose.duration` / AssemblyAI `audio_duration`. Estimation fallback not needed — capture point must be inside provider functions, not orchestrator.
- [T1 Model pricing](tickets/T1-pricing-rates.md) — rates verified 2026-07-14 ([pricing.md](pricing.md)): summary per-token in/out, transcription per-duration; gemini-2.5-pro tiered by prompt size. Store snapshot `costUSD` at run time (not recompute-on-read); rates live in a `pricing.ts` + `pricedAsOf`, not the registry. Registry pins a stale model generation (out of scope).
- [T4 History schema](tickets/T4-history-schema.md) — `HistoryRecord.usage?: UsageEntry[]` (additive, undefined=legacy). Entry per (model,task): `{modelId, task, provider, calls, tokensIn?, tokensOut?, durationMin?, costUSD|null, estimated}`. Cost snapshotted at write from `pricing.ts` (gemini-pro tiered branch). Two-phase write (transcription→create, summary→complete). Legacy: reclaim transcription cost via duration×rate (estimated), summary cost `null`/unknown.
- [T5 Aggregation grain](tickets/T5-aggregation-grain.md) — two views: (1) per-model summary, rollup per `modelId`, cost-desc, columns model·provider·runs·calls·tokensIn·tokensOut·$, windowed (all-time/30d/month); (2) per-run cost log. Estimated rows `~`-marked; unknown cost shows `—`, excluded from total + "N unknown" footnote.

## Not yet specified

<!-- in-scope fog; graduates to tickets as the frontier advances -->

- ~~Estimation fallback for token-less providers (Whisper) + legacy history rows — sharpens after T2 usage-capture audit.~~ **Resolved by T2:** no provider needs estimation fallback. Whisper `TranscriptionVerbose.duration` and AssemblyAI `audio_duration` expose duration directly; Chat Completions expose tokens directly. For legacy history rows (no captured usage), duration×rate estimation per-provider still applies as a fallback interpretation.
- ~~Historical backfill / recompute of past runs once a pricing table exists — sharpens after T4 schema.~~ **Resolved by T4:** no backfill job — legacy rows are interpreted on read (transcription cost via duration×rate, summary cost `null`/unknown). Nothing rewrites old records.
- ~~Pricing-staleness handling in the UI ("rates as of <date>", manual-update cadence) — sharpens after T1.~~ **Resolved by T1:** rates live in a `pricing.ts` table with a `pricedAsOf` date; UI shows a "rates as of <date>" disclaimer. Snapshot cost at run time so past runs are immune to rate changes.

## Out of scope

- Budgets, spend limits, alerts, or any enforcement — this effort is **reporting only**.
- Live in-run cost HUD / real-time meter — stats are post-hoc over history, not a during-run overlay.
- **Registry model refresh** (surfaced by T1): OpenAI's lineup moved to gpt-5.6/5.5/5.4 and AssemblyAI deprecated `slam-1` / retired `nano`, so `src/registry.ts` pins a stale generation. Real, but a registry-maintenance effort separate from usage-stats reporting — redraw as its own effort if wanted.

## Tickets

| Ticket | Type | Status | Blocked by |
|---|---|---|---|
| [T1 Model pricing: rates + billing basis](tickets/T1-pricing-rates.md) | research | closed | — |
| [T2 Per-call usage capture audit](tickets/T2-usage-capture.md) | research | closed | — |
| [T3 CLI scope: macOS-only or `nota usage` too](tickets/T3-cli-scope.md) | grilling | open | — (frontier) |
| [T4 History schema: per-run per-model usage + migration](tickets/T4-history-schema.md) | grilling | closed | T1 ✅, T2 ✅ |
| [T5 Aggregation grain for the stats view](tickets/T5-aggregation-grain.md) | grilling | closed | T4 ✅ |
| [T6 Home-page stats panel design](tickets/T6-homepage-prototype.md) | prototype | open | T3, T5 ✅ (still blocked by T3) |
