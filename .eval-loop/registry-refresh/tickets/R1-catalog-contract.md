<!-- wayfinder:research -->
# R1 — Catalog contract: models.dev shape → Nota schema

status: closed
blocked-by: none (frontier)

## Question

Fetch `https://models.dev/api.json` and pin the exact contract Nota depends on:

- Field shape for the three summary providers (`openai`, `google`, `deepseek`):
  id, name, cost (input/output/cache_read), limits, modality/capability flags —
  which fields exist and which are optional?
- **Allowlist predicates as code**: exact filter expressions that admit mainline
  chat models (locked rule 3 on the map) against today's data, with the resulting
  id list printed. Verify they exclude codex/pro/chat-latest/realtime/preview/
  image/tts/lite variants and admit gpt-5.4/-mini, gpt-5.5, gpt-5.6-terra,
  gemini-3.5-flash, gemini-3-pro (when stable), deepseek-v4-flash/pro.
- **Id mapping**: Nota reaches Gemini through the OpenAI-compatible endpoint —
  do models.dev `google` ids match what that endpoint accepts? Same question for
  DeepSeek. Any alias table needed?
- **Tiered pricing**: gemini pro models bill differently ≤/>200k prompt tokens —
  does models.dev encode tiers, or does the catalog need a manual tier overlay?
- **Trust/validation**: minimum sanity checks before accepting a fetched catalog
  (schema-validate, non-empty per provider, cost fields numeric, size cap) so a
  bad/hijacked response can't wipe the pickers.
- Proposed `~/.nota/models-catalog.json` schema: filtered entries + `fetchedAt`
  (doubles as `pricedAsOf`) + source etag/hash.

Deliverable: `assets/catalog-contract.md` with the schema, predicates, alias
table, and open risks. No code beyond throwaway probing.

## Resolution

Resolved 2026-07-21 via three parallel Opus research agents (shape / id-mapping /
pricing), all findings verified against a live api.json fetch + live provider
`/models` probes + Google's pricing page. Contract: [catalog-contract.md](../assets/catalog-contract.md);
lane detail: [R1-shape.md](../assets/R1-shape.md), [R1-idmap.md](../assets/R1-idmap.md),
[R1-pricing.md](../assets/R1-pricing.md); runnable predicates: [allowlist.js](../assets/allowlist.js).

Headlines:
- **No alias table** — models.dev ids are the endpoint `model` params verbatim
  (Gemini invariant: bare id, never the `models/`-prefixed live-list form).
- **Predicates locked + run against real data**: admit 8 OpenAI / 4 Google /
  2 DeepSeek today; OpenAI `family` field is corrupted — id-regex + modality
  gate instead; recommend generalizing the OpenAI regex to `gpt-\d+` so gpt-6
  auto-admits.
- **Tiered pricing IS encoded** (`cost.tiers[]`, threshold from `tier.size` —
  varies 200k/272k/…; ignore legacy `context_over_200k`). Catalog cost fully
  replaces pricing.ts for summary models. **Unit trap: per-1M-tokens vs
  pricing.ts per-token (×1e-6).**
- **Trust rules + cache schema (v1) specified** — etag conditional GET, numeric
  bounds, blanking guard, stale-serve on failure, atomic write; `fetchedAt`
  doubles as `pricedAsOf`.
- models.dev membership ≠ callable (lists dead deepseek aliases) — allowlist
  exclusion is load-bearing. Transcription lane confirmed fully outside the
  catalog (no assemblyai, no openai audio ids).
