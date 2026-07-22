# R1 lane: models.dev ids vs OpenAI-compatible endpoint `model` params

(r1-idmap agent, 2026-07-21)

**Bottom line: no id-rewriting alias table needed for any of the 3 providers. models.dev ids are already in the exact form each `model` param accepts. Two caveats: strip `models/` if ids ever come from a live `/models` list (Gemini), and filter models.dev's supersets (deprecated + non-chat ids).**

## 1. Nota's current endpoints (quoted, `src/registry.ts`)
```ts
export const GEMINI_OPENAI_BASE_URL =
  "https://generativelanguage.googleapis.com/v1beta/openai/";   // registry.ts:39-40
export const DEEPSEEK_BASE_URL = "https://api.deepseek.com";     // registry.ts:46
// OpenAI: no baseURL entry → OpenAI SDK default https://api.openai.com/v1
const BASE_URL = { gemini: GEMINI_OPENAI_BASE_URL, deepseek: DEEPSEEK_BASE_URL }; // registry.ts:56-59
```
The registry id is passed **verbatim** as the `model` param — `src/pipeline/summarize.ts:229` / `:269` do `client.chat.completions.create({ model, ... })`. The only provider branch is the token-cap key (`max_tokens` for Gemini vs `max_completion_tokens` otherwise, `summaryTokenLimit`, summarize.ts:214-221) plus the base-URL swap. So whatever id is stored must be exactly what the endpoint's `model` field accepts.

## 2. Per-provider id-format findings (live probes, 2026-07-21)

**OpenAI — `api.openai.com/v1`**
- Probe `GET /v1/models` (123 ids): bare — `gpt-5`, `gpt-5-mini`, `gpt-4o`, `gpt-4.1` all present verbatim.
- models.dev `openai` (56 ids): bare, identical.
- Verdict: **models.dev id == endpoint id, verbatim.**

**Google/Gemini — `generativelanguage.googleapis.com/v1beta/openai/`**
- Probe `GET .../openai/models` (57 ids): returns **`models/`-prefixed** — `models/gemini-2.5-flash`, `models/gemini-3.5-flash`, `models/gemini-3-pro-preview`.
- models.dev `google` (25 ids): **bare** — `gemini-2.5-flash`, `gemini-3-pro-preview`, `gemini-3.5-flash`, `gemini-3.6-flash`; all 25 exist in the live list after adding the prefix.
- **The `model` param wants bare.** Google's OpenAI-compat docs use `model="gemini-3.6-flash"` in every example; the `models/` prefix is only Google's list-resource convention, not the chat `model` value. Nota already ships bare `gemini-2.5-flash` through this endpoint in production (registry.ts:104-105), confirming bare is accepted.
- Verdict: **models.dev id (bare) == endpoint `model` id (bare). Never source ids from the live `/models` list without stripping `models/`.**

**DeepSeek — `api.deepseek.com`**
- Probe `GET /models`: returns exactly **2** ids — `deepseek-v4-flash`, `deepseek-v4-pro` (bare, verbatim). Legacy `deepseek-chat`/`deepseek-reasoner` already **absent**.
- models.dev `deepseek` (4 ids): the two v4 ids **plus** `deepseek-chat`, `deepseek-reasoner`.
- Verdict: **models.dev v4 ids == endpoint ids, verbatim.** models.dev is a superset that still lists the two deprecated aliases the endpoint no longer serves (matches registry.ts:106-108). Nota's registry already excludes them.

## 3. Alias table

| Provider | models.dev id → endpoint `model` | Rule |
|---|---|---|
| OpenAI | `gpt-5-mini` → `gpt-5-mini` | none needed |
| Gemini | `gemini-2.5-flash` → `gemini-2.5-flash` | none needed — use models.dev's bare form; never the `models/`-prefixed form from a live `/models` list |
| DeepSeek | `deepseek-v4-pro` → `deepseek-v4-pro` | none needed |

## 4. Risks
1. **models.dev ⊋ live endpoint (superset/staleness).** models.dev lists ids the endpoint rejects — concretely DeepSeek `deepseek-chat`/`deepseek-reasoner` (dead at probe time). Sourcing the `deepseek` key wholesale registers two ids that fail at call time. Needs a filter (intersect with live `/models`, or keep the curated exclusion) — models.dev membership ≠ endpoint availability.
2. **Transcription uncovered.** models.dev's `openai` key lists **no** audio/transcription models (no `whisper-1`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`); AssemblyAI has no models.dev-style catalog. Only the **summary** side can be sourced from models.dev; transcription ids stay curated.
3. **Non-chat ids in the same provider key.** `google`/`openai` keys mix image/tts/embedding/video/realtime models (`gemini-2.5-flash-image`, `gpt-image-1`, `text-embedding-3-large`, `veo-*`). Filtering by top-level provider key alone pulls non-summarizable ids into the picker — needs a task/modality filter.
4. **Gemini list-vs-call divergence is a latent trap.** Live `/models` returns `models/`-prefixed but the `model` param wants bare. Any future "verify against the live list" or copy-from-list code silently produces failing ids. Encode bare as the invariant.
5. **Bare-Gemini acceptance is doc- + production-grounded, not freshly call-proven** (no paid chat call made). Zero-cost live confirmation available via the existing `canarySummaryModel` canary (summarize.ts:258, `max_tokens:1`).

## Sources
- Local: `src/registry.ts` (39-59, 104-110), `src/pipeline/summarize.ts` (214-283).
- Live probes 2026-07-21: `GET generativelanguage.googleapis.com/v1beta/openai/models` (57, prefixed); `GET api.deepseek.com/models` (2: v4-flash/v4-pro); `GET api.openai.com/v1/models` (123, bare).
- models.dev: `https://models.dev/api.json` (google 25 / deepseek 4 / openai 56).
- https://ai.google.dev/gemini-api/docs/openai — bare `model="gemini-3.6-flash"`, no `models/` prefix.
- https://developers.googleblog.com/en/gemini-is-now-accessible-from-the-openai-library/
