# HANDOFF X1 — Self-updating model catalog (TypeScript side)

Self-contained. Assume no prior conversation. Repo: `/Users/xiafawu/Developer/Nota`.
Branch **off `master`** (fresh branch, e.g. `feat/model-catalog`). No other feature
branches are in flight; do not commit to `master` directly.

## Context

Nota is a TypeScript CLI (ESM, vitest) that transcribes audio (AssemblyAI/Whisper)
and summarizes with an OpenAI/Gemini/DeepSeek model. `src/registry.ts` is the
hardcoded single source of truth for valid model ids; it has gone stale (OpenAI a
generation behind; AssemblyAI `slam-1` deprecated / `nano` retired). This task makes
the **summary-model** side self-updating from https://models.dev/api.json via a
weekly-refreshed local cache. A macOS app consumes the same cache later (X2 — NOT
this task). Full research detail lives in `.eval-loop/registry-refresh/assets/`
(committed): `catalog-contract.md` is the canonical contract; `allowlist.js` has
reference predicates; `R1-*.md` have the evidence. This handoff inlines everything
needed; consult those files only to resolve ambiguity.

## Hard constraints (do-NOT-touch fence)

- `macos/**` — zero changes. Swift/X2 comes later.
- `src/pipeline/assemblyai.ts`, `transcribe.ts`, `diarize.ts`, `embed.ts`,
  `speakers.ts`, `chunk.ts`, `merge.ts`, `validate.ts`, `align`— transcription
  pipeline untouched.
- `scripts/**`, `docs/**` (except README.md at repo root), `.eval-loop/**`.
- `~/.nota/settings.json` schema stays exactly
  `{ "transcription": { "model": string }, "summary": { "model": string } }`.
- `HistoryRecord` schema: additive only; existing `usage` entry shape
  (`{modelId, task, provider, calls, tokensIn?, tokensOut?, durationMin?, costUSD, estimated}`)
  unchanged.
- Keep all legacy MeetingSum compatibility aliases as-is.
- **Transcription entries in `registry.ts` stay static** — but REMOVE `slam-1`
  and `nano` (retired by vendor; part of this task's zombie cleanup).
- Tests must not hit the network. Fixture-based only.

## Locked decisions (settled — do not re-open)

1. **Architecture:** runtime weekly refresh. On CLI startup, if
   `~/.nota/models-catalog.json` is missing or `fetchedAt` older than 7 days,
   fetch `https://models.dev/api.json` in the background (never blocks or fails a
   run), filter through the allowlist, validate, atomic-write (temp file +
   rename). A **baked snapshot** (JSON committed in `src/`) is the no-cache
   fallback. Conditional GET with stored `etag` (`If-None-Match`); 304 → keep
   cache, bump nothing but the freshness clock (store `checkedAt` alongside if
   needed).
2. **Allowlist (auto-admit):** structural gate first — `modalities.output`
   exactly `["text"]`, no `"audio"` in `modalities.input`, `tool_call === true` —
   then per provider:
   - openai: id matches `/^gpt-\d+(\.\d+)?(-mini)?$/` (generalized so gpt-6
     auto-admits). Ignore the `family` field — it is corrupted upstream.
   - google: `family` is `"gemini-flash"` or `"gemini-pro"`, id contains neither
     `preview` nor `latest`, and `status !== "deprecated"`.
   - deepseek: id matches `/^deepseek-v([4-9]|\d{2,})-(flash|pro)$/`.
   Today this admits: gpt-5, gpt-5-mini, gpt-5.1, gpt-5.2, gpt-5.4, gpt-5.4-mini,
   gpt-5.5, gpt-5.6 / gemini-2.5-flash, gemini-2.5-pro, gemini-3.5-flash,
   gemini-3.6-flash / deepseek-v4-flash, deepseek-v4-pro.
3. **Ids are used verbatim** as the OpenAI-compatible `model` param (verified by
   live probes). Gemini ids are the bare form (`gemini-2.5-flash`) — never
   `models/`-prefixed. No alias table.
4. **Zombie policy:** a configured summary model absent from the effective
   catalog → hide from valid ids, **warn on stderr once per run**
   (`model X is no longer available; using <resolved-default>`), resolve to the
   default chain. Exit code unaffected. History records referencing old ids
   untouched.
5. **Key-aware default chain for summary:** `deepseek-v4-flash` if
   `DEEPSEEK_API_KEY` resolves → else `gpt-5.4-mini` if `OPENAI_API_KEY` → else
   `gemini-3.6-flash` if `GEMINI_API_KEY` → else error listing the three options.
   (Chain entries resolve against the catalog; if a chain id is itself absent,
   fall to the next.) When the chain skips deepseek for lack of key, add one
   stderr note suggesting `DEEPSEEK_API_KEY` for the cheaper default.
   Transcription default stays `universal`. CLI flag > settings.json > chain,
   unchanged precedence.
6. **Pricing:** `src/pricing.ts` shrinks to **transcription-only** per-duration
   rates. Summary cost at snapshot time comes from the catalog entry (cache →
   baked fallback): `costUSD = tokensIn*rate.input*1e-6 + tokensOut*rate.output*1e-6`
   picking the tier with the largest `thresholdTokens ≤ prompt tokens` (else base
   rates). **models.dev rates are USD per 1M tokens; existing code is per-token —
   the ×1e-6 conversion is mandatory and must have a dedicated assertion test.**
   Missing cost data → `costUSD: null` (existing "unknown" semantics, excluded
   from totals). A run's `pricedAsOf` = catalog `fetchedAt`.
7. **Catalog cache schema** (`~/.nota/models-catalog.json`, `schemaVersion: 1`,
   read later by Swift — camelCase, optional scalars omitted never null, `tiers`
   always present as array):

```json
{
  "schemaVersion": 1,
  "source": "https://models.dev/api.json",
  "etag": "\"...\"",
  "fetchedAt": "2026-07-22T05:23:33Z",
  "costUnit": "usd_per_1m_tokens",
  "models": [
    { "id": "gemini-2.5-pro", "provider": "google", "label": "Gemini 2.5 Pro",
      "task": "summary",
      "cost": { "input": 1.25, "output": 10, "cacheRead": 0.125,
        "tiers": [ { "thresholdTokens": 200000, "input": 2.5, "output": 15, "cacheRead": 0.25 } ] },
      "limit": { "context": 1048576, "output": 65536 } }
  ]
}
```

   Mapping from api.json: flatten `cost.tiers[].tier.size` → `thresholdTokens`
   (all tiers are context-type; drop any non-context tier); **ignore the legacy
   `context_over_200k` field entirely** (misnamed mirror — thresholds actually
   vary: 200k, 272k, …); provider key `google` maps to Nota provider `gemini`.
8. **Fetch validation** (reject fetch, keep old cache, on any failure): HTTPS,
   host `models.dev`, no cross-host redirect, ~10 s timeout, ≤16 MB, JSON
   content-type; `openai`+`google`+`deepseek` present with non-empty `models`;
   each retained entry has string `id` and numeric `cost.input`/`cost.output`;
   bounds `0 ≤ input,output ≤ 5000` (per 1M), `0 ≤ cache_read ≤ input`,
   `thresholdTokens` positive int; blanking guard — a currently-configured
   model's cost going 0/missing while the old cache has it non-zero rejects the
   fetch.
9. **UX:** new CLI verb `nota models refresh` — forces a fetch (ignores TTL),
   prints added/removed ids vs previous cache to stdout, confirmation to stderr;
   non-zero exit on validation failure. `nota models list` — prints effective
   summary catalog (id, provider, label, source: cache|baked) tab-separated on
   stdout. `nota usage` output gains a footer line
   `model catalog as of <fetchedAt>` on stderr.

## Task + lane manifest

**L1 (sequential, first) — catalog module.** New `src/catalog.ts`: fetch,
allowlist filter, validation, atomic cache write, TTL check, baked-snapshot
fallback, effective-catalog resolution (cache → baked), tier-pick + cost-compute
helpers. Baked snapshot: generate `src/models-catalog.baked.json` by running the
new fetch+filter pipeline once live at build time of this PR (a one-off script
invocation is fine; do not commit the raw 3.2 MB api.json). Owned files:
`src/catalog.ts`, `src/models-catalog.baked.json`, `tests/catalog/*`.

**L2 (parallel-safe after L1) — registry/config/settings.** `src/registry.ts`:
transcription entries stay static (minus slam-1/nano); summary entries resolve
from the effective catalog; keep `getModel`/`requireModel`/`isGeminiModel` API
shape (map catalog `provider: "google"` → `"gemini"`, derive `apiKeyEnv`,
baseURL unchanged). `src/config.ts`: key-aware default chain + zombie
warn-and-fallback. `src/utils/settings.ts`: `settings set` validates against the
effective catalog; storing a currently-valid id stays allowed. Owned:
`src/registry.ts`, `src/config.ts`, `src/utils/settings.ts`, their tests.

**L3 (parallel-safe after L1) — pricing/usage.** `src/pricing.ts` →
transcription-only; summary snapshot cost from catalog via L1 helpers;
`pricedAsOf` per run = catalog `fetchedAt`; null-cost = unknown semantics
preserved. Owned: `src/pricing.ts`, `src/usage-stats.ts`,
`src/pipeline/history.ts` (only the cost-snapshot site), their tests.

**L4 (parallel-safe after L1) — CLI surface.** New `src/cli/models.ts`
(`refresh`/`list` verbs), hookup in `src/index.ts` (verb + startup background
TTL check), `src/cli/usage.ts` footer. Owned: `src/cli/models.ts`,
`src/index.ts`, `src/cli/usage.ts`, their tests.

**L5 (parallel-safe, any time) — docs.** README.md + CLAUDE.md model sections:
valid summary ids are now rule-described ("mainline chat models auto-admitted
weekly from models.dev; run `nota models list`"), transcription ids enumerated
(universal, whisper-1, gpt-4o-transcribe, gpt-4o-mini-transcribe), new default
chain documented, `nota models` verbs documented, DEEPSEEK note. Owned:
`README.md`, `CLAUDE.md`.

One commit per lane minimum. If lanes L2–L4 in one agent, still commit per lane.

## Stop-fence

X1 ONLY. Do NOT start X2 (macOS/Swift reads the cache — later ticket), do NOT
touch `macos/**`, do NOT add a scheduled/cron anything, do NOT redesign Settings
UI, do NOT implement transcription-model refresh (no data source exists).

## Verify (run all; paste real output)

- `npm test` — full suite green. **Named required tests (part of the fence —
  their absence is a spec violation):**
  1. `tests/catalog/validate.test.ts` — every §8 rule incl. blanking guard and
     bounds rejection.
  2. `tests/catalog/allowlist.test.ts` — fixture api.json slice admits exactly
     the 14 ids listed in decision 2 and excludes near-misses
     (`gpt-5.4-pro`, `gpt-5.3-chat-latest`, `gpt-5.1-codex`, `gpt-5.6-sol`,
     `gemini-3-pro-preview`, `gemini-3.1-flash-lite`, `gemini-flash-latest`,
     `gemini-2.5-flash-image`, `deepseek-chat`, `deepseek-reasoner`).
  3. `tests/catalog/cost.test.ts` — **×1e-6 unit assertion** (e.g. 10k in +
     1k out on gpt-5-mini = $0.0045) and tier pick at a non-200k threshold
     (synthetic 272k fixture: below/above threshold rates differ).
  4. `tests/config/default-chain.test.ts` — chain order with each key-presence
     combination incl. no-keys error.
  5. `tests/config/zombie-fallback.test.ts` — stale settings id warns on stderr
     and resolves to chain default; exit code 0.
- `npm run build` — clean compile.
- `node dist/index.js models list` (or `npm start -- models list`) with no cache
  present — prints the baked-snapshot ids, exits 0, no network needed.

## Required reply template

Reply using exactly these sections:
```
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine/data)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
```
