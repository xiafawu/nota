<!-- wayfinder:grilling -->
# T4 — History schema: per-run per-model usage + migration

status: closed
blocked-by: T1, T2 (both closed)

## Question

How is per-run, per-model usage stored in the history record, and what happens to legacy records?

A single run uses ≥2 models (transcribe + summarize; possibly section+rollup summary calls). So a run needs an **array** of usage rows, e.g. `usage: [{ model, task, provider, tokensIn?, tokensOut?, durationMin?, costUSD, estimated: bool }]`.

- Exact field set (informed by T2's capture-map — which fields are ever available).
- Is `costUSD` stored (snapshot at run time, robust to later price changes) or recomputed from stored tokens × current rates on read? (T1 price-volatility finding informs this.)
- Legacy records (no `usage`, only `durationMinutes`): shown as "unknown", excluded, or best-effort estimated? (ties to the estimation-fallback fog item.)
- Where the write happens (orchestrator vs each stage) and back-compat with the existing `HistoryRecord` shape in `src/pipeline/history.ts`.

Resolve via `/grilling` + `/domain-modeling`. Blocked until T1 (rates/volatility) and T2 (available fields) are known.

## Inputs from T2 (closed)

- **Capture point is fixed**: usage is only visible inside the provider function right after the API response; current return types strip it. Schema work must assume the emission point is *inside* each stage — cleanest path found: widen `callGPT()` → `{content, usage}` and accumulate in `summarizeTranscript()`; extend transcription returns to include duration. See [capture-map.md](../capture-map.md).
- **Live capture needs no estimation** (tokens from Chat Completions `response.usage`; duration from Whisper `TranscriptionVerbose.duration` / AssemblyAI `audio_duration`). Estimation remains only for **legacy rows** with no stored usage — a T4 migration decision, not a live-path one.

## Resolution

New field `HistoryRecord.usage?: UsageEntry[]` — optional/additive, `undefined` = legacy (same back-compat pattern as `contentHash?`).

**Entry shape (Q1 = C):**
```ts
interface UsageEntry {
  modelId: string;
  task: "transcription" | "summary";
  provider: Provider;
  calls: number;              // e.g. 7 for section+rollup summary
  tokensIn?: number;          // summary models
  tokensOut?: number;         // summary models
  durationMin?: number;       // transcription models
  costUSD: number | null;     // null = unknown (never 0 when unknowable)
  estimated: boolean;         // true = derived (legacy duration×rate), not API-reported
}
```

**Cost (Q3 + T1):** `costUSD` computed at **write time** from a `pricing.ts` table (snapshot, not recompute-on-read). Tiered models (gemini-2.5-pro) branch on `tokensIn` (≤/>200k). Rate table carries `pricedAsOf`.

**Emission (Q3 = A):** two-phase, mirrors the existing lifecycle —
- transcription usage → `CreateHistoryInput.usage` (written when transcript lands; survives a later summary crash).
- summary usage → appended via `CompleteHistoryInput.usage` (written when summary lands).
- Capture point is inside each provider fn (T2): widen `callGPT()` → `{content, usage}`, sum across section+rollup calls into one summary entry with `calls`; transcription returns duration.

**Legacy rows (Q2 = B/C):** no `usage` field → reclaim transcription cost from stored `durationMinutes × rate` (`estimated: true`); summary entry `costUSD: null` (unknown, shown explicitly, never $0). New rows are fully known.

Downstream: T5 aggregates these entries; the `estimated` flag + `null` cost drive its "estimated/unknown" display treatment.
