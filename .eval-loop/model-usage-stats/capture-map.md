# Capture Map — Per-call usage data available at each provider call site

## Summary

| Call site | Provider | Model(s) | Tokens-in available? | Tokens-out available? | Duration available? | Needs estimation fallback? | Capture point |
|---|---|---|---|---|---|---|---|
| `src/pipeline/transcribe.ts` `transcribeChunks()` — `client.audio.transcriptions.create` with `response_format: "verbose_json"` | OpenAI (Whisper) | `whisper-1` (default), any Whisper model | **No** — Whisper models billed by audio duration, not tokens | **No** — Whisper models billed by audio duration, not tokens | **Yes** — `response.duration: number` (seconds) always present on `TranscriptionVerbose`. Also `response.usage?.seconds` for duration-billed models | Duration exposed directly — no estimation needed for duration. Token-based estimation never applies (models don't expose tokens) | Inside the per-chunk callback in `transcribeChunks()`. Currently only `text` and `segments` are extracted — the raw `response` (typed `TranscriptionVerbose`) carries `duration`. Need to capture before returning. For multi-chunk runs, sum `duration` across chunks |
| `src/pipeline/assemblyai.ts` `transcribeWithAssemblyAI()` — `client.transcripts.transcribe` | AssemblyAI | `universal` (default), `slam-1`, `nano` | **No** — AssemblyAI bills by audio duration ($/hr) | **No** | **Yes** — `transcript.audio_duration: number` (seconds) on the response `Transcript` type | Duration exposed directly — no estimation needed. However, `audio_duration` is optional (`?`) in the type — always present in practice but code should handle absence with orchestrator-computed `durationMinutes` fallback | Inside `transcribeWithAssemblyAI()` after the `transcribe()` call returns. Currently only `utterances` and `text` are extracted. Or at the orchestrator level in `runAssemblyAIPipelineInner()` since `durationMinutes` is already computed there from `getAudioDuration()` |
| `src/pipeline/summarize.ts` `callGPT()` — `client.chat.completions.create` | OpenAI (Chat Completions) | `gpt-5-mini` (default), any OpenAI chat model | **Yes** — `response.usage.prompt_tokens: number` | **Yes** — `response.usage.completion_tokens: number` | **No** — text-only API | No estimation needed — tokens are directly exposed by the API response | Inside `callGPT()` — change return type from `Promise<string>` to `{ content: string; usage: CompletionUsage }`. For the >100k section-then-rollup path in `summarizeTranscript()`, each section call + the rollup call each return distinct usage; caller must sum them into a per-run aggregate |
| `src/pipeline/summarize.ts` `callGPT()` via OpenAI-compat endpoint | Gemini (Google) | Any Gemini model (`gemini-2.5-flash`, `gemini-2.5-pro`, etc.) | **Yes** — Gemini's OpenAI-compat endpoint returns `usage` with `prompt_tokens` | **Yes** — Same response shape with `completion_tokens` | **No** — text-only API | No estimation needed — mapped from Gemini's `usageMetadata` to OpenAI's `CompletionUsage` shape | Same as above — `callGPT()` handles both providers transparently. The OpenAI SDK parses both responses into the same `ChatCompletion` type |

## Detailed call sites

### 1. Whisper — `src/pipeline/transcribe.ts` (line 35)

**Request:**
```ts
const response = await client.audio.transcriptions.create({
  file: createReadStream(chunkPath),
  model,
  response_format: "verbose_json",
  timestamp_granularities: ["segment"],
  ...(language ? { language } : {}),
});
```

**Response type:** `TranscriptionVerbose` (`node_modules/openai/resources/audio/transcriptions.d.ts:450`).

**Usage fields exposed:**
- `duration: number` — always present; the duration of the input audio in seconds
- `usage?: { seconds: number; type: 'duration' }` — present only for newer duration-billed models; not guaranteed for `whisper-1`

**What's captured today:** Only `response.text` and `response.segments` (the latter via `(response as any).segments` cast). `duration` and `usage` are discarded.

**What would change:** Extract `response.duration` (and optionally `response.usage?.seconds`) from each chunk callback. For multi-chunk runs, sum across chunks for total duration.

**Estimation fallback:** None needed for duration — it's directly on the response. But the orchestrator already computes `durationMinutes` via `getAudioDuration()` in `runPipeline()`, which could serve as a cross-check or fallback if `response.duration` is unexpectedly missing.

### 2. AssemblyAI — `src/pipeline/assemblyai.ts` (line 80)

**Request:**
```ts
const transcript = await client.transcripts.transcribe(params);
```

**Response type:** `Transcript` (`node_modules/assemblyai/src/types/openapi.generated.ts:2644`).

**Usage fields exposed:**
- `audio_duration?: number | null` — duration in seconds (optional in type; always present on a completed transcript in practice)
- No token info — AssemblyAI bills by audio duration only

**What's captured today:** Only `transcript.utterances` and `transcript.text`. `audio_duration` is discarded.

**What would change:** Extract `transcript.audio_duration` after the transcribe call.

**Estimation fallback:** The orchestrator already computes `durationMinutes` via `getAudioDuration()` at `orchestrator.ts:97-98`, before any pipeline call. This is the fallback if `audio_duration` is null/undefined. Note: for the AssemblyAI path, `durationMinutes` is passed as a parameter to `runAssemblyAIPipeline()` and `runAssemblyAIPipelineInner()`, so it's already available at the capture point.

### 3. OpenAI Chat Completions — `src/pipeline/summarize.ts` (line 206)

**Request:**
```ts
const response = await client.chat.completions.create({
  model,
  ...summaryTokenLimit(model, 4096),
  messages: [{ role: "user", content: prompt }],
});
```

**Response type:** `ChatCompletion` (`node_modules/openai/resources/chat/completions/completions.d.mts`).

**Usage fields exposed:**
- `usage?: CompletionUsage` where:
  - `prompt_tokens: number`
  - `completion_tokens: number`
  - `total_tokens: number`
  - `completion_tokens_details?: { … }` (optional breakdown)
  - `prompt_tokens_details?: { … }` (optional breakdown)
- No duration

**What's captured today:** Only `response.choices[0].message.content`. The full `response` including `usage` is discarded.

**What would change:**
- `callGPT()` return type: `Promise<string>` → `Promise<{ content: string; usage: ChatCompletion.Usage }>` (or a narrower type with just the token fields).
- `summarizeTranscript()` accumulates usage across all `callGPT()` calls (section summaries + rollup) into a single aggregate.
- For Gemini via OpenAI-compat: the same `usage` shape is returned (Gemini translates `usageMetadata` to the OpenAI format).

**Estimation fallback:** Not needed — tokens are directly available from the API. However, for the `>100k` section-then-rollup path, the token counts from all calls must be summed.

### 4. Gemini (via OpenAI-compat) — same function as #3

Same `callGPT()` function handles both via `baseURL` routing — Gemini uses `https://generativelanguage.googleapis.com/v1beta/openai/`. The OpenAI SDK parses the Gemini response into the same `ChatCompletion` shape, so `usage.prompt_tokens` and `usage.completion_tokens` are available identically.

## Where per-model usage records should be emitted

The usage data is only visible **inside each provider function** immediately after the API call returns. The current return types strip it:

1. **`callGPT()` → `string`**: Need to return `{ content: string; usage: tokens }`. The caller (`summarizeTranscript()`) must accumulate across multiple calls.
2. **`transcribeChunks()` → `TranscriptionResult[]`**: Need to also return `totalDurationSeconds` (and/or per-chunk usage). Currently each chunk's response is cast as `any` and only `text`/`segments` survive.
3. **`transcribeWithAssemblyAI()` → `TranscriptionResult`**: Same — `audio_duration` is discarded.

Recommended approach: **Push capture into the provider layer** (change return types to include usage), not the orchestrator. The orchestrator only sees `TranscriptionResult` and `MeetingSummary` — neither carries usage data today. There are two design options:

- **A) Extend return types**: `callGPT` returns `{content, usage}`, `summarizeTranscript` returns `{summary, totalUsage}`, transcription functions return `{result, duration}`. Cleanest, but changes many signatures.
- **B) Side-channel capture**: A usage accumulator object passed through the pipeline, updated by each provider function via mutation. Less disruptive to types but opaque.
