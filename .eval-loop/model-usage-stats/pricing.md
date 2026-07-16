# Model pricing — T1 asset

Rates verified against official provider pages, **2026-07-14**. All USD. Prices are volatile; treat this table as a point-in-time snapshot, not a live source.

## Summary models (per 1M tokens, in / out)

| Model | Provider | Input | Output | Source |
|---|---|---|---|---|
| gpt-5-mini | OpenAI | $0.25 | $2.00 | [model page](https://developers.openai.com/api/docs/models/gpt-5-mini) |
| gpt-5 | OpenAI | $1.25 | $10.00 | [model page](https://developers.openai.com/api/docs/models/gpt-5) |
| gpt-4o | OpenAI | $2.50 | $10.00 | [model page](https://developers.openai.com/api/docs/models/gpt-4o) |
| gpt-4.1 | OpenAI | $2.00 | $8.00 | [model page](https://developers.openai.com/api/docs/models/gpt-4.1) |
| gemini-2.5-flash | Gemini | $0.30 (text) | $2.50 | [pricing](https://ai.google.dev/gemini-api/docs/pricing) |
| gemini-2.5-pro | Gemini | $1.25 (≤200k) / $2.50 (>200k) | $10.00 (≤200k) / $15.00 (>200k) | [pricing](https://ai.google.dev/gemini-api/docs/pricing) |

Billing basis = per-token, input and output priced separately.

## Transcription models

| Model | Provider | Rate | Unit | Source |
|---|---|---|---|---|
| universal (→ universal-2) | AssemblyAI | $0.15 | per audio hour | [pricing](https://www.assemblyai.com/pricing) |
| whisper-1 | OpenAI | $0.006 | per audio minute | OpenAI audio pricing (verify — page now foregrounds gpt-4o-transcribe at same rate) |
| gpt-4o-transcribe | OpenAI | $0.006 | per audio minute | [pricing](https://developers.openai.com/api/docs/pricing) |
| gpt-4o-mini-transcribe | OpenAI | $0.003 | per audio minute | [pricing](https://developers.openai.com/api/docs/pricing) |

Billing basis = per audio duration (hour for AssemblyAI, minute for OpenAI), not tokens.

## Findings that feed downstream tickets

1. **Registry staleness (out of scope for this feature, but flag it).**
   - OpenAI's live lineup is now gpt-5.6-sol/terra/luna, gpt-5.5, gpt-5.4(-mini). Nota's registry pins the older gpt-5 / gpt-5-mini / gpt-4o / gpt-4.1 — still individually priced on model pages, but a generation behind.
   - AssemblyAI **deprecated `slam-1`** ("migrate to universal-3-pro") and **retired `nano`** (routes to universal-2). Both are still valid ids in `src/registry.ts`.
   - This is a registry-refresh concern, separate from the reporting feature. Recorded as Out of scope on the map.

2. **Volatility → store snapshot cost, not recompute-on-read (input to T4).** Rates change with model generations and models get deprecated. Persisting `costUSD` computed at run time is robust; recomputing from stored tokens × *current* rates breaks when a model's rate changes or disappears.

3. **Tiered pricing (input to T4).** gemini-2.5-pro is priced by prompt size (≤200k vs >200k tokens). Cost is not a single per-model rate — the calculator must branch on input token count for tiered models.

4. **Where rates live (recommendation, decided in T4).** Keep pricing OUT of `src/registry.ts` (registry is the model-identity SSOT; pricing is volatile and orthogonal). Put a `pricing.ts` table keyed by model id with a `pricedAsOf` date, feeding a "rates as of <date>" UI disclaimer (the T1 fog item).
