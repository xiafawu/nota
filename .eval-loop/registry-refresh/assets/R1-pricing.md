# R1 lane: tiered pricing, trust rules, cache schema

(r1-pricing agent, 2026-07-21)

> Synthesis note: the agent flagged the api.json snapshot as a "synthetic/future fixture" because it contains gpt-5.6/gemini-3.6 and 2026 dates — that is knowledge-cutoff confusion, the snapshot was fetched live this session (2026-07-21) and its Gemini rates cross-check exactly against Google's live pricing page. Treat the data as real; the recommendation to re-validate against a fresh fetch before shipping numbers stands anyway.

## 1. Tiered pricing — encoded; catalog can replace the manual table for summary models

Encoded in two redundant forms inside `cost`:

```json
// google/gemini-2.5-pro (excerpt)
"cost": {
  "input": 1.25, "output": 10, "cache_read": 0.125,
  "tiers": [
    { "input": 2.5, "output": 15, "cache_read": 0.25,
      "tier": { "type": "context", "size": 200000 } }
  ],
  "context_over_200k": { "input": 2.5, "output": 15, "cache_read": 0.25 }
}
```

- `tiers[]` = structured form. Base `cost.*` applies at or below threshold; tier rates above `tier.size` prompt tokens.
- `context_over_200k` = legacy flat mirror of `tiers[0]`. **Misnamed — ignore it.**

Global tier scan (259 tier-entries, every provider):
- `tier.type` always `"context"` (0 exceptions).
- `tier.size` varies: **200000 (115×), 272000 (73×)**, 256000 (38×), 128000 (14×), 32000 (12×), 512000 (6×), 16000 (1×). OpenAI gpt-5.x tiers at **272000** while the legacy key is still named `context_over_200k` — consumers MUST read `tiers[].tier.size`, never hardcode 200k.
- Some models carry >1 tier entry (step pricing). Treat `tiers` as N-entry array.

Google cross-check (live ai.google.dev pricing) — dataset matches exactly:

| Model | Threshold | ≤ thr in/out | > thr in/out | Matches? |
|---|---|---|---|---|
| Gemini 2.5 Pro | 200k | $1.25 / $10 | $2.50 / $15 | yes, exact |
| Gemini 3.1 Pro Preview | 200k | $2.00 / $12 | $4.00 / $18 | yes, exact |
| Gemini 2.5 Flash | flat | $0.30 / $2.50 | n/a | yes, no tier |

Verdict: **catalog cost fully replaces `src/pricing.ts` for summary models** — provided snapshot code (a) reads threshold from `tiers[].tier.size`, (b) ignores `context_over_200k`, (c) handles N tiers. Of Nota's current summary set only `gemini-2.5-pro` is tiered; gpt-5.x flat (272k figure there is an input *limit*, not a price tier).

**⚠ Unit mismatch:** models.dev costs are **USD per 1,000,000 tokens**; existing `src/pricing.ts` is **per-token**. Migration must multiply by `1e-6`. Highest-likelihood migration bug — add a unit assertion/test.

**⚠ Transcription NOT covered** (no assemblyai provider; no whisper/gpt-4o-transcribe under canonical `openai`). Catalog is summary-only.

## 2. Cost-field inventory (USD per 1M tokens; fields sparse)

| field | openai | google | deepseek | meaning |
|---|---|---|---|---|
| `input` / `output` | all | all | all | base rates |
| `cache_read` | 40/56 | 16/25 | 4/4 | cached-input read |
| `cache_write` | gpt-5.x (4) | — | — | cache-write surcharge |
| `input_audio` | 1 | 9 | — | audio input |
| `output_audio` | 1 | — | — | audio output |
| `tiers` | 8 | 4 | — | threshold overrides |
| `context_over_200k` | 8 | 4 | — | legacy mirror — ignore |

Tier-entry fields (subset of base): `input`, `output`, `cache_read`, `cache_write`, `input_audio`; may omit `cache_read`.

Nota-relevant raw values (per 1M tokens):
```
gpt-5-mini        in 0.25   out 2     cache_read 0.025          (flat)
gpt-5             in 1.25   out 10    cache_read 0.125          (flat)
gpt-4o            in 2.5    out 10    cache_read 1.25           (flat)
gpt-4.1           in 2      out 8     cache_read 0.5            (flat)
gemini-2.5-flash  in 0.3    out 2.5   cache_read 0.03           (flat)
gemini-2.5-pro    in 1.25   out 10    cache_read 0.125  TIER@200k -> 2.5/15/0.25
deepseek-v4-flash in 0.14   out 0.28  cache_read 0.0028         (flat)
deepseek-v4-pro   in 0.435  out 0.87  cache_read 0.003625       (flat)
```
Sub-cent precision — store full float, never round in the cache.

## 3. Validation rules before a fetched catalog replaces the cache

Transport/freshness (live header probe: `HTTP/2 200`, `content-type: application/json`, `etag: "a0cb67f7ce74d398c2ca028c7bf75842"`, `cache-control: public, max-age=0, must-revalidate`, no `Last-Modified`, Cloudflare-fronted):
- HTTPS-only, host pinned to `models.dev`; reject cross-host redirects.
- Conditional GET with `If-None-Match: <stored etag>`; on 304 keep cache, bump refresh clock.
- Timeout ~10 s; response size cap ~16 MB (real file 3.2 MB); require parseable JSON + JSON content-type.

Structural/schema:
- Top level object; required providers `openai`, `google`, `deepseek` present with non-empty `models` — else fail.
- Currently-selected + default summary ids must resolve; missing non-selected id → warn only.
- Every retained entry: string `id`; `cost` with numeric `input` and `output`.

Numeric sanity (per 1M tokens; guards unit slips):
- `0 ≤ input, output ≤ 5000` (observed real max ≈ 270); `cache_read ≥ 0` and `≤ input`; `tier.size` positive int; warn if tier rate < base.
- Blanking guard: required model's cost 0/missing while current cache non-zero → reject fetch.

On any failure: keep existing cache, stderr warning, serve stale (never block pipeline). No cache → built-in baked fallback. Atomic write (temp + rename). Weekly TTL off `fetchedAt`. Filter to summary allowlist at fetch time (3.2 MB → few KB).

## 4. Proposed `~/.nota/models-catalog.json` schema

Conventions (Codable + TS friendly): flatten tier to `thresholdTokens` int (all tiers are context-type; drop non-context tiers if they ever appear); drop `context_over_200k`; camelCase; optional cost scalars OMITTED when absent (never null); `tiers` ALWAYS present (`[]` when flat); `cost.input`/`output` required; flat `models` array, each entry carries `provider`.

```json
{
  "schemaVersion": 1,
  "source": "https://models.dev/api.json",
  "etag": "a0cb67f7ce74d398c2ca028c7bf75842",
  "fetchedAt": "2026-07-22T05:23:33Z",
  "costUnit": "usd_per_1m_tokens",
  "models": [
    {
      "id": "gemini-2.5-pro",
      "provider": "google",
      "label": "Gemini 2.5 Pro",
      "task": "summary",
      "cost": {
        "input": 1.25, "output": 10, "cacheRead": 0.125,
        "tiers": [
          { "thresholdTokens": 200000, "input": 2.5, "output": 15, "cacheRead": 0.25 }
        ]
      },
      "limit": { "context": 1048576, "output": 65536 }
    },
    {
      "id": "deepseek-v4-flash",
      "provider": "deepseek",
      "label": "DeepSeek V4 Flash",
      "task": "summary",
      "cost": { "input": 0.14, "output": 0.28, "cacheRead": 0.0028, "tiers": [] },
      "limit": { "context": 1000000, "output": 384000 }
    }
  ]
}
```

Field notes: `schemaVersion` int, unknown → discard cache + refetch/fallback; `etag` for conditional GET (`""` if absent); `fetchedAt` ISO-8601 UTC Z, doubles as `pricedAsOf`; snapshot algo picks tier with largest `thresholdTokens ≤ promptTokens`, else base cost; `limit`: `context` + optional `output`/`input`.

## 5. Open risks

- Threshold ≠ 200k for many models (OpenAI 272k) — enforce "read `tiers[].tier.size`" in review.
- Per-token vs per-million unit slip vs existing pricing.ts — unit assertion/test required.
- Transcription uncovered — registry stays SoT; transcription cost stays hand-maintained.
- Multi-tier models exist — schema + consumer handle N tiers.
- Community data, no SLA — validation + keep-old-cache + numeric bounds are the guardrails.
- `cacheRead` may be uncomputable in-app (needs per-run cache-hit token counts Nota doesn't track) — treat cache fields as informational; snapshot uses input+output.

Sources: models.dev api.json (live fetch + `curl -sI` header probe), https://ai.google.dev/gemini-api/docs/pricing, https://pricepertoken.com/pricing-page/model/google-gemini-3.1-pro-preview, https://www.cloudzero.com/blog/gemini-pricing/
