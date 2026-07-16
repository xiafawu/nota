<!-- wayfinder:research -->
# T1 — Model pricing: current rates + how each provider bills

status: closed
blocked-by: none (frontier)

## Question

For every model in `src/registry.ts` (transcription: universal, slam-1, nano, whisper-1, gpt-4o-transcribe, gpt-4o-mini-transcribe; summary: gpt-5-mini, gpt-5, gpt-4o, gpt-4.1, gemini-2.5-flash, gemini-2.5-pro), what is the current price and **billing basis**?

- OpenAI/Gemini summary models: $ per 1M input tokens + $ per 1M output tokens.
- OpenAI transcription (whisper-1, gpt-4o-transcribe*): per-minute or per-token?
- AssemblyAI (universal/slam-1/nano): $ per hour/second of audio.
- Note which prices are volatile and where the authoritative source lives (provider pricing pages).

Deliverable: a `pricing.md` asset (rate table + billing basis + source links + a recommendation on where rates should live in code — registry field vs separate table). Storage *decision* is deferred to T4; this ticket just gathers the facts + a recommendation.

## Resolution

Rates verified 2026-07-14 against official provider pages → [pricing.md](../pricing.md). Summary models are per-token in/out (gpt-5-mini $0.25/$2, gpt-5 $1.25/$10, gpt-4o $2.50/$10, gpt-4.1 $2/$8, gemini-2.5-flash $0.30/$2.50, gemini-2.5-pro tiered by prompt size). Transcription is per-duration (AssemblyAI universal $0.15/hr; OpenAI whisper-1 / gpt-4o-transcribe $0.006/min, gpt-4o-mini-transcribe $0.003/min).

Findings feeding downstream:
- **Volatility → snapshot `costUSD` at run time**, don't recompute from current rates on read (input to T4).
- **gemini-2.5-pro is tiered** by prompt size (≤/>200k) — cost calc must branch (input to T4).
- **Rates belong in a `pricing.ts` table with a `pricedAsOf` date**, not in `registry.ts` (volatile ≠ identity SSOT). Resolves the pricing-staleness fog item.
- **Registry staleness** (out of scope): OpenAI moved to gpt-5.6/5.5/5.4; AssemblyAI deprecated `slam-1`, retired `nano`. Registry pins a stale generation — a separate maintenance concern, ruled Out of scope.
