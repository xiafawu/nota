# PI Build Spec — Usage/cost data layer (headless)

Self-contained. Assume no prior conversation. This is an **implementation** task in the Nota repo (`/Users/xiafawu/Developer/Nota`), spun out of a planning effort. You build the decision-complete **data layer** for a per-model money/token usage feature. You do NOT build any UI, CLI command, or macOS code — those decisions are still open and out of your scope.

## Context

Nota is a TypeScript CLI + pipeline (`src/`) that transcribes then summarizes audio. Today it records `~/.nota/history` entries with `durationMinutes` but **no token/cost data**. Four design tickets are locked (see `.eval-loop/model-usage-stats/` — `pricing.md`, `capture-map.md`, `tickets/T1,T2,T4,T5`). This task implements exactly what those four locked. Two tickets (CLI scope, UI panel) are still open — so **stop at the headless data + aggregator layer; render nothing.**

## Scope — build these, nothing more

### 1. `src/pricing.ts` (new)
Rate table + cost function. Source of numbers: `.eval-loop/model-usage-stats/pricing.md`.
- Export a table keyed by registry model id with `pricedAsOf: "2026-07-14"`.
  - Summary (per 1M tokens in/out): gpt-5-mini `0.25/2.00`, gpt-5 `1.25/10.00`, gpt-4o `2.50/10.00`, gpt-4.1 `2.00/8.00`, gemini-2.5-flash `0.30/2.50`, gemini-2.5-pro **tiered**: ≤200k in `1.25/10.00`, >200k in `2.50/15.00`.
  - Transcription (per unit): AssemblyAI universal `0.15/hr`; whisper-1 `0.006/min`, gpt-4o-transcribe `0.006/min`, gpt-4o-mini-transcribe `0.003/min`. (whisper-1 rate flagged "verify" in T1 — use it, leave a `// TODO verify` comment.)
- Export `costForUsage(entry): number | null` computing USD from a `UsageEntry` (see below): tokens×rate for summary (branch gemini-2.5-pro on `tokensIn`), duration×rate for transcription. Return `null` when inputs are absent (unknown).
- Unit tests: each model, the gemini tier boundary, and the null path.

### 2. `UsageEntry` type + schema field (`src/pipeline/history.ts`)
- Add:
  ```ts
  export interface UsageEntry {
    modelId: string;
    task: "transcription" | "summary";
    provider: Provider;
    calls: number;
    tokensIn?: number;
    tokensOut?: number;
    durationMin?: number;
    costUSD: number | null;   // null = unknown, never 0 when unknowable
    estimated: boolean;
  }
  ```
- Add `usage?: UsageEntry[]` to `HistoryRecord` (optional/additive — `undefined` = legacy, same back-compat pattern as `contentHash?`). Add `usage?: UsageEntry[]` to `CreateHistoryInput`; add `usage?: UsageEntry[]` to `CompleteHistoryInput` (appended to the record's array on complete).

### 3. Capture plumbing (usage is only visible inside the provider fn — see capture-map.md)
- `src/pipeline/summarize.ts`: widen `callGPT()` (line ~201) to return `{ content, usage }` where usage = `{ promptTokens, completionTokens }` from `response.usage`. In `summarizeTranscript()` (~267), accumulate across the section+rollup calls into ONE summary `UsageEntry` with `calls` = number of `callGPT` invocations, summed `tokensIn`/`tokensOut`, `costUSD` from `costForUsage`, `estimated: false`.
- `src/pipeline/transcribe.ts` (`transcribeChunks`) and `src/pipeline/assemblyai.ts` (`transcribeWithAssemblyAI`): surface audio duration (`response.duration` / `transcript.audio_duration`) so a transcription `UsageEntry` can be built (`durationMin`, `calls: 1`, `estimated: false`).

### 4. Two-phase write (`src/orchestrator.ts`)
- Both pipeline branches call `createHistoryRecord` (lines ~319, ~608) then `completeHistoryRecord` (~368, ~654).
- Pass the transcription `UsageEntry` into `CreateHistoryInput.usage`; pass the summary `UsageEntry` into `CompleteHistoryInput.usage`. Compute `costUSD` at write time via `costForUsage`. (Two-phase so a summary failure still persists transcription usage.)

### 5. Aggregator — pure, headless (`src/usage-stats.ts`, new)
Pure functions over `HistoryRecord[]`, NO rendering, NO CLI wiring:
- `perModelSummary(records, window?)` → rows `{ modelId, provider, runs, calls, tokensIn, tokensOut, costUSD, hasUnknown }`, sorted cost desc. `window` filters on `createdAt` (all-time | 30d | month).
- `perRunLog(records)` → `{ id, createdAt, models: [...], totalCostUSD }[]`.
- **Legacy rows** (`usage` undefined): reclaim transcription cost from `durationMinutes × rate` (`estimated: true`); summary cost `null`/unknown. Exclude `null` costs from totals; surface `hasUnknown`/an unknown count so totals never silently understate.
- Unit tests: mixed legacy+new records, windowing, unknown-exclusion.

## Hard constraints — do NOT

- **No UI, no macOS/Swift, no CLI command.** CLI scope (`nota usage`) and the home-page panel are undecided (open tickets T3, T6). Build the headless layer only; render nothing.
- Do not change `src/registry.ts` model list, or model ids.
- Do not change the `~/.nota/settings.json` schema.
- Keep all additions back-compatible: existing history records (no `usage`) must still load and behave exactly as today.

## Verify

- `npm run build` clean; `npm test` green (new tests included).
- Load an existing pre-feature history record → no crash, `usage` undefined, unchanged behavior.
- Run a real transcribe+summarize → the new record has a transcription entry and a summary entry with sane `costUSD`.
- `git status` touches only `src/**` (+ tests). No `macos/**`, no `.eval-loop/**` edits, no UI.

## Note on wayfinder

This is an execution slice of a still-open planning map. It implements only the four LOCKED tickets (T1/T2/T4/T5). Do not resolve or edit the map tickets; do not build ahead into T3 (CLI) or T6 (UI). Report what you built + test results.
