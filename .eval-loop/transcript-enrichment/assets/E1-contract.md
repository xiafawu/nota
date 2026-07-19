# E1 — Split-generation contract

Researched 2026-07-18 against `src/pipeline/summarize.ts`, `src/pricing.ts`,
`src/pipeline/history.ts`, `src/utils/tokens.ts`. Recommendations only; E4 locks.

## Three operations

| Op | Input | Prompt | Output |
|---|---|---|---|
| Full summarize (exists) | transcript/segments | `buildSummaryPrompt` unchanged | `MeetingSummary` incl. tags |
| Summary-only refresh | transcript/segments | `buildSummaryPrompt(…, { includeTags: false })` — same prompt minus the `### Tags` block | `MeetingSummary` with `tags` untouched on the record (edited-is-protected) |
| Tags-only | see input ladder below | new `buildTagsPrompt` | `string[]` (3–6 tags) |

All three share `callGPT`, `summaryTokenLimit` (the per-provider cap-key branch), and
the existing client/baseURL wiring — no new request plumbing.

### buildTagsPrompt draft

```
You are labeling a meeting transcript with topical tags.

## Transcript

<text>

## Instructions

Reply with ONLY one line: 3 to 6 short, lowercase topical tags,
comma-separated (for example: planning, roadmap, hiring). No other text.
```

Token cap for the tags call: **1024** — looks absurd for a one-line answer, but
reasoning models (gpt-5*, deepseek-v4-flash) burn budget on reasoning tokens before
emitting content; a tight cap yields `content: ""` + `finish_reason: "length"` (the
PolishClient lesson, PR #54).

### Validation contract

`parseTags(content)` (existing) then **throw if the result is empty** — empty or
malformed LLM content is a failure, never success. Callers surface the error;
nothing writes an empty `tags: []` over existing data. Same rule for summary-only:
`parseSummaryResponse` must yield a non-empty `narrative` or the op fails.

## Model choice: the configured summary model — not a hardcoded cheaper one

Recommendation: **reuse whatever summary model config resolves** (default gpt-5-mini).
The decisive argument is keys, not cost: the registry's rule is "only the keys the
resolved models need." Hardcoding deepseek-v4-flash for tags would make tags-only
require `DEEPSEEK_API_KEY` from users who configured OpenAI — a new failure mode to
save a fraction of a cent. Cost table for a typical 1-hour meeting (~12k tokens in,
~20 tags tokens out; rates from `pricing.ts`, verified 2026-07-14/15):

| Model | Tags-only cost | Note |
|---|---|---|
| gpt-5-mini (default) | ~$0.0030 | recommended path |
| deepseek-v4-flash | ~$0.0017 | cheapest; needs its own key; reasoning-burn risk |
| gemini-2.5-flash | ~$0.0036 | |
| gpt-5 | ~$0.015 | if user configured it, still trivial |

Summary-only refresh ≈ current full-summary cost (~$0.005–0.02 typical) — same input,
slightly fewer output tokens.

## Tags-only input ladder (handles the >100k case for free)

1. **Summary exists on the record** → tag from `narrative + keyTopics` (~500 tokens in,
   ~$0.0002). Fastest, cheapest, and tags describe the summary the user actually sees.
2. **No summary, transcript fits** (`shouldChunkTranscript` false) → whole
   `transcriptText`.
3. **No summary, transcript >100k tokens** → do NOT run the section+rollup flow for a
   one-line answer; concatenate evenly-sampled excerpts (head + middle + tail slices)
   into a ≤50k-token single call. Tags are topical gist — sampling is adequate, and
   this caps worst-case cost at ~$0.013 (gpt-5-mini).

## Usage capture: reuse `task: "summary"`

Recommendation: tags-only and summary-only calls record a `UsageEntry` with the
existing `task: "summary"` via `makeSummaryUsage` (whose docstring already anticipates
a re-summarize CLI). Rationale: cost math is identical (per-token in/out, tiered
gemini branch included), `usage-stats` rolls up per model so no aggregation change,
and the Swift `ModelUsageRow` schema stays untouched. Tradeoff: tags spend is not
separately visible in `nota usage` — at ~$0.003/run that granularity isn't worth a
union-member ripple through `costForUsage`, usage-stats, and the cost card. If E3
decides otherwise, the alternative is `task: "tags"` + one new `costForUsage` branch.

Appending the new entry to `HistoryRecord.usage[]` means on-demand enrichment spend
lands in the cost card automatically once the record is re-saved — no further wiring.

## API shape (TS lane preview)

```ts
// summarize.ts additions
export function buildSummaryPrompt(transcript, hasSpeakers, opts?: { includeTags?: boolean }): string
export function buildTagsPrompt(text: string): string
export async function generateTags(text, apiKey, model, baseURL?):
  Promise<{ tags: string[]; tokenUsage: {calls, tokensIn, tokensOut} }>
export async function summarizeOnly(...same shape as summarizeTranscript, tags omitted)
```

CLI verbs (locked at charting): `nota summarize <history-id>`, `nota tag <history-id>`
— both load the record's `transcriptText`, run the op, append usage, save via the
history module, rewrite the `.md`.
