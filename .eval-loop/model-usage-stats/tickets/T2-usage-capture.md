<!-- wayfinder:research -->
# T2 — Per-call usage capture audit

status: closed
blocked-by: none (frontier)

## Question

At each provider call site, what usage data does the SDK response actually expose, and how do we capture it?

- `src/pipeline/summarize.ts` (OpenAI + Gemini via OpenAI-compat) — does the response carry `usage.prompt_tokens` / `completion_tokens`? For the >100k section-then-rollup path, usage is per-call — how is it summed?
- `src/pipeline/transcribe.ts` (Whisper) — does it return any token/duration usage, or must we derive from audio length?
- `src/pipeline/assemblyai.ts` — is `audio_duration` returned on the transcript object? (maps to $/hr).
- Where would a per-model usage record be emitted from — inside each stage, or collected by the orchestrator?

Deliverable: a `capture-map.md` asset — one row per call site: {provider, model, what the response exposes, tokens-in/out available?, duration available?, capture point}. Flags which providers need estimation fallback (feeds the fog item).

## Resolution

All three call sites audited in [capture-map.md](../capture-map.md).

| Call site | Tokens-in | Tokens-out | Duration | Fallback needed? |
|---|---|---|---|---|
| OpenAI Chat Completions (callGPT, summarize.ts) | `response.usage.prompt_tokens` ✅ | `response.usage.completion_tokens` ✅ | N/A | No — tokens directly from API; Gemini compat returns same shape |
| Whisper (transcribe.ts, `response_format: "verbose_json"`) | N/A (duration-billed) | N/A (duration-billed) | `response.duration` ✅ (`TranscriptionVerbose`) | No — duration exposed directly; orchestrator `getAudioDuration()` as cross-check |
| AssemblyAI (assemblyai.ts) | N/A (duration-billed) | N/A (duration-billed) | `transcript.audio_duration` ✅ | Minor — `audio_duration` is optional-nullable in type; orchestrator `durationMinutes` already computed |

All three providers expose usage data at the API response level but **none is captured today** — return types strip it before the orchestrator sees it. **Estimation fallback is not needed** for any provider: tokens are direct from Chat Completions, duration is direct from Whisper `TranscriptionVerbose.duration` and AssemblyAI `audio_duration`. The orchestrator-computed `getAudioDuration()` value serves as a cross-check.

Key finding for map: capture point must be *inside* the provider function (usage is only visible right after the API response). Cleanest path: change `callGPT()` return type to `{content, usage}` and accumulate in `summarizeTranscript()`; extend transcription returns to include duration.
