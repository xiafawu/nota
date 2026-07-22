# Catalog contract: models.dev → Nota

R1 deliverable, synthesized 2026-07-21 from three research lanes:
[R1-shape.md](R1-shape.md) (field shape + predicates), [R1-idmap.md](R1-idmap.md)
(endpoint id mapping), [R1-pricing.md](R1-pricing.md) (tiers, trust, schema).
Runnable predicates: [allowlist.js](allowlist.js). All findings verified against a
live 2026-07-21 fetch of `https://models.dev/api.json` + live provider `/models`
probes + Google's pricing page.

## The contract in one paragraph

Nota fetches `https://models.dev/api.json` (conditional GET on stored etag,
HTTPS-only, 10 s timeout, 16 MB cap), filters it through the three allowlist
predicates below, validates the survivors (schema + numeric bounds + blanking
guard), and atomically writes a few-KB `~/.nota/models-catalog.json` (schema §4)
that both the TS CLI and Swift app read for summary-model ids, labels, limits, and
cost. Ids are used **verbatim** as the OpenAI-compatible `model` param — no alias
table. On any fetch/validation failure the old cache is kept and served stale;
with no cache, a baked snapshot ships in-repo. Transcription models never come
from the catalog.

## 1. Allowlist predicates (locked rule: mainline chat only)

Structural gate first — `modalities.output === ["text"]`, no audio input,
`tool_call === true` — then per provider:

| Provider | Predicate | Today admits |
|---|---|---|
| openai | gate + `/^gpt-5(\.\d+)?(-mini)?$/` — **ignore `family`, it is corrupted** (`gpt-5-chat-latest` is tagged `gpt-codex`) | gpt-5, gpt-5-mini, gpt-5.1, gpt-5.2, gpt-5.4, gpt-5.4-mini, gpt-5.5, gpt-5.6 |
| google | `family ∈ {gemini-flash, gemini-pro}` + text-only + no `/preview/`, no `/latest/`, `status !== "deprecated"` | gemini-2.5-flash, gemini-2.5-pro, gemini-3.5-flash, gemini-3.6-flash |
| deepseek | `/^deepseek-v([4-9]|\d{2,})-(flash|pro)$/` (family ambiguous — id is the only discriminator) | deepseek-v4-flash, deepseek-v4-pro |

Verified excluded: all codex/pro/nano/chat-latest/sol/luna/terra OpenAI variants,
gemini preview/lite/image/latest/gemma, deepseek legacy aliases. X1 decision
carried forward: generalize OpenAI to `/^gpt-\d+(\.\d+)?(-mini)?$/` so gpt-6
auto-admits (Google is already forward-compatible via family; DeepSeek via
version pattern).

## 2. Id mapping: none needed

models.dev ids == endpoint `model` params **verbatim** for all three providers
(live-probed). Invariants to encode:

- Gemini: always the **bare** id (`gemini-2.5-flash`); the live `/models` list
  returns `models/`-prefixed ids — never source ids from it unstripped.
- models.dev membership ≠ callable: it still lists dead `deepseek-chat`/
  `deepseek-reasoner` (endpoint serves only v4-flash/pro). The allowlist
  predicates already exclude both; that exclusion is load-bearing.

## 3. Trust & validation (before replacing the cache)

- Transport: HTTPS, host pinned `models.dev`, no cross-host redirects,
  `If-None-Match` conditional GET (304 → keep cache, bump clock), ~10 s timeout,
  16 MB cap, JSON content-type. Server sends etag, no Last-Modified.
- Schema: top-level object; `openai`/`google`/`deepseek` present, non-empty
  `models`; retained entries need string `id` + numeric `cost.input`/`output`.
  Current + default summary ids must resolve (missing others → warn only).
- Bounds: `0 ≤ input,output ≤ 5000` per 1M tokens; `0 ≤ cache_read ≤ input`;
  `tier.size` positive int. Blanking guard: a required model's cost going
  0/missing while cached non-zero rejects the fetch.
- Failure → keep old cache + stderr warning, never block a run. No cache →
  baked snapshot. Writes atomic (temp + rename).

## 4. Cache schema (`~/.nota/models-catalog.json`, schemaVersion 1)

Flat `models` array; camelCase; optional scalars omitted (never null); `tiers`
always present (`[]` when flat); `fetchedAt` doubles as `pricedAsOf`; costs
**USD per 1M tokens** (`costUnit` self-documents). Full example + field notes in
[R1-pricing.md](R1-pricing.md) §4.

```
{ schemaVersion, source, etag, fetchedAt, costUnit, models: [
  { id, provider, label, task: "summary",
    cost: { input, output, cacheRead?, tiers: [{ thresholdTokens, input, output, cacheRead? }] },
    limit: { context, output?, input? } } ] }
```

## 5. Pricing facts feeding G2

- models.dev **does** encode tiered pricing: `cost.tiers[]` with
  `tier.{type:"context", size}`. Read the threshold from `tiers[].tier.size` —
  thresholds vary (200k, 272k, 256k, …); **ignore the misnamed legacy
  `context_over_200k` mirror**. Handle N tiers.
- Rates cross-check exactly against Google's live pricing page (2.5-pro tier
  verified). Catalog cost can fully replace `pricing.ts` for summary models.
- **Unit trap:** models.dev is per-1M-tokens, existing `pricing.ts` is per-token
  — multiply by 1e-6 on migration, add a unit assertion test.
- `cacheRead` needs per-run cache-hit counts Nota doesn't track — informational
  only; snapshots use input+output.

## 6. Open risks (carried to G2/X1)

1. OpenAI regex version-lock (mitigation chosen: generalize digit).
2. Preview-only models never admitted (accepted consequence of stability rule).
3. Community data, no SLA — guardrails are §3 validation + stale-serve.
4. Transcription lane fully outside this contract: registry.ts stays SSOT for
   AssemblyAI + OpenAI audio ids and their (duration-based) pricing.
5. `limit.input` (272k on gpt-5.x) is a context limit, not a price tier — don't
   conflate with tier thresholds.
