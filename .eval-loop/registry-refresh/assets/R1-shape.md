# R1 lane: models.dev catalog contract — field shape + allowlist predicates

(r1-shape agent, 2026-07-21. Runnable predicates: [allowlist.js](allowlist.js))

Source: `https://models.dev/api.json` (3.2 MB, fetched 2026-07-21). Top-level object = **169 provider keys**; each provider is `{ id, env, npm, name, doc, models, [api] }` where `models` is an id→object map. Analyzed: `openai` (56 models), `google` (25), `deepseek` (4).

Provider-level auth fields (for Nota key resolution):
- `openai.env = ["OPENAI_API_KEY"]`, no `api` (default base URL)
- `google.env = ["GOOGLE_API_KEY","GOOGLE_GENERATIVE_AI_API_KEY","GEMINI_API_KEY"]`, no `api`
- `deepseek.env = ["DEEPSEEK_API_KEY"]`, `api = "https://api.deepseek.com"`

## 1. Per-model field shape

### ALWAYS present (all three providers)
`id`, `name`, `description`, `family`, `attachment` (bool), `reasoning` (bool), `tool_call` (bool), `temperature` (bool), `release_date`, `last_updated`, `modalities` (`{input:[], output:[]}` — both arrays always present), `open_weights` (bool), `limit` (`{context, output}` always; `.input` optional — 31/56 openai, absent all google/deepseek here).

### Optional (presence varies)
| field | openai | google | deepseek | meaning |
|---|---|---|---|---|
| `cost` | 52/56 | 23/25 | 4/4 | `{input,output}` $/M-tok; `.cache_read` common (40/56,16/25,4/4); `.tiers[]`+`.context_over_200k` for tiered pricing (8/56,4/25); `.cache_write`,`.input_audio`,`.output_audio` rare |
| `knowledge` | 51/56 | 22/25 | 4/4 | training-cutoff date string |
| `structured_output` | 46/56 | 18/25 | 2/4 | bool |
| `reasoning_options` | 36/56 | 20/25 | 3/4 | array; shape differs by provider |
| `experimental` | **7/56** | — | — | **OpenAI only**; alternate serving tiers |
| `status` | — | **4/25** | — | **Google only**; observed value `"deprecated"` |
| `interleaved` | — | — | 3/4 | DeepSeek only; `{field:"reasoning_content"}` |

Key structural facts:
- **`modalities.output` is the cleanest capability discriminator.** Chat = `["text"]`; image = `["text","image"]`/`["image"]`; tts/omni = `["audio"]`/`["video"]`. Embeddings are `["text"]` but `tool_call:false`.
- **`reasoning_options` shape is provider-specific**: OpenAI `[{type:"effort",values:[...]}]`; Google `[{type:"budget_tokens",min,max}]`; DeepSeek `[{type:"toggle"},{type:"effort",values:[...]}]`. Not uniform.
- **`family` is inconsistent for OpenAI** and unreliable there (see §4). It IS reliable for Google (`gemini-flash`/`gemini-pro`/`gemini-flash-lite`/`gemini`/`gemma`) and useless for DeepSeek (`deepseek-v4-pro` and legacy `deepseek-reasoner` both `deepseek-thinking`).
- **No top-level `deprecated`/`preview` boolean and no EOL date field.** Preview lives only in the `id` (`-preview`); EOL lives only in Google's `status:"deprecated"`. OpenAI marks neither.

### Sample objects (verbatim)

**openai / `gpt-5.2`**
```json
{ "id": "gpt-5.2", "name": "GPT-5.2",
  "description": "Reliable GPT generation for broad coding, writing, and tool-assisted product work",
  "family": "gpt", "attachment": true, "reasoning": true,
  "reasoning_options": [{ "type": "effort", "values": ["none","low","medium","high","xhigh"] }],
  "tool_call": true, "structured_output": true, "temperature": false,
  "knowledge": "2025-08-31", "release_date": "2025-12-11", "last_updated": "2025-12-11",
  "modalities": { "input": ["text","image"], "output": ["text"] },
  "open_weights": false,
  "limit": { "context": 400000, "input": 272000, "output": 128000 },
  "cost": { "input": 1.75, "output": 14, "cache_read": 0.175 } }
```

**google / `gemini-2.5-pro`** (tiered pricing)
```json
{ "id": "gemini-2.5-pro", "name": "Gemini 2.5 Pro",
  "description": "Google's proven reasoning model for coding, math, and multimodal analysis",
  "family": "gemini-pro", "attachment": true, "reasoning": true,
  "reasoning_options": [{ "type": "budget_tokens", "min": 128, "max": 32768 }],
  "tool_call": true, "structured_output": true, "temperature": true,
  "knowledge": "2025-01", "release_date": "2025-06-17", "last_updated": "2025-06-17",
  "modalities": { "input": ["text","image","audio","video","pdf"], "output": ["text"] },
  "open_weights": false,
  "limit": { "context": 1048576, "output": 65536 },
  "cost": { "input": 1.25, "output": 10, "cache_read": 0.125,
    "tiers": [{ "input": 2.5, "output": 15, "cache_read": 0.25, "tier": { "type": "context", "size": 200000 } }],
    "context_over_200k": { "input": 2.5, "output": 15, "cache_read": 0.25 } } }
```

**deepseek / `deepseek-v4-pro`** (`interleaved`, `open_weights:true`)
```json
{ "id": "deepseek-v4-pro", "name": "DeepSeek V4 Pro",
  "description": "Open MoE flagship with million-token context for coding and long agent runs",
  "family": "deepseek-thinking", "attachment": false, "reasoning": true,
  "reasoning_options": [{ "type": "toggle" }, { "type": "effort", "values": ["high","max"] }],
  "tool_call": true, "interleaved": { "field": "reasoning_content" },
  "structured_output": true, "temperature": true,
  "knowledge": "2025-05", "release_date": "2026-04-24", "last_updated": "2026-04-24",
  "modalities": { "input": ["text"], "output": ["text"] },
  "open_weights": true,
  "limit": { "context": 1000000, "output": 384000 },
  "cost": { "input": 0.435, "output": 0.87, "cache_read": 0.003625 } }
```

## 2. Predicates (summary — full runnable script in [allowlist.js](allowlist.js))

- Structural gate `isChatTextModel`: `modalities.output === ["text"]` AND no audio input AND `tool_call === true` — removes image/realtime/tts/embedding.
- **OpenAI**: gate + id regex `/^gpt-5(\.\d+)?(-mini)?$/` (rejects -pro/-nano/-codex/-chat-latest/-sol/-luna/-terra). `family` deliberately ignored (corrupted, see §4).
- **Google**: `family in {gemini-flash, gemini-pro}` + text-only output + no `/preview/`, no `/latest/`, `status !== "deprecated"`.
- **DeepSeek**: id regex `/^deepseek-v([4-9]|\d{2,})-(flash|pro)$/` (family ambiguous; version pattern is the only reliable discriminator).

## 3. Admitted / excluded — real run output

**OpenAI — 8/56 admitted:** `gpt-5`, `gpt-5-mini`, `gpt-5.1`, `gpt-5.2`, `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.5`, `gpt-5.6`
**Google — 4/25 admitted:** `gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-3.5-flash`, `gemini-3.6-flash`
**DeepSeek — 2/4 admitted:** `deepseek-v4-flash`, `deepseek-v4-pro`

**Near-miss verification (all EXCLUDED — run prints "PASS"):**
| id | why excluded |
|---|---|
| `gpt-5.4-pro` | `-pro` suffix fails OPENAI_MAINLINE regex |
| `gpt-5.3-chat-latest` | `-chat-latest` fails regex (note: `family:"gpt"`, so family would NOT catch it) |
| `gpt-5-nano` | `-nano` fails regex (mini-only rule) |
| `gpt-5.1-codex` | `-codex` fails regex |
| `gpt-5.6-sol` | `-sol` named variant fails regex |
| `gpt-realtime-2.1` | structural gate: input+output contain audio |
| `gemini-3-pro-preview` | `/preview/` (also `status:"deprecated"`) |
| `gemini-3.1-flash-lite` | `family:"gemini-flash-lite"` out of scope |
| `gemini-2.0-flash` | `status:"deprecated"` |
| `gemini-flash-latest` | `/latest/` floating alias |
| `gemini-2.5-flash-image` | `output:["text","image"]` fails text-only |
| `gemma-4-31b-it` | `family:"gemma"` out of scope |
| `deepseek-chat` / `deepseek-reasoner` | no version number, fail DEEPSEEK_VN |

Other true exclusions: `gpt-5-pro`,`gpt-5.2-pro`,`gpt-5.5-pro` (pro); `gpt-5.4-nano` (nano); `gpt-5.6-luna`,`gpt-5.6-terra` (named variants); `gpt-5-codex`,`gpt-5.1-codex-max/-mini`,`gpt-5.3-codex-spark` (codex); `gemini-3-flash-preview`,`gemini-3.1-pro-preview`,`gemini-3.5-flash-lite`,`gemini-flash-lite-latest`,`gemini-omni-flash-preview` (preview/lite/omni).

## 4. Fragility notes

1. **OpenAI `family` is corrupted as a filter — do NOT key off it.** `gpt-5-chat-latest` is `family:"gpt-codex"`; `gpt-5.3-chat-latest` is `family:"gpt"`; `gpt-5.6` and `gpt-5.6-sol` are both `family:"gpt-sol"`. The OpenAI predicate uses id-regex + modality gate instead. Google's `family` is clean and IS used; DeepSeek's is ambiguous and is NOT.
2. **OpenAI `experimental` ≠ preview/unstable.** `gpt-5.4`, `gpt-5.5`, `gpt-5.6` (all admitted mainline) carry `experimental` blocks holding alternate *serving tiers* (`fast`/`pro` with `service_tier:"priority"` pricing), not preview flags. Naive "exclude if experimental" wrongly drops three mainline models. Predicate ignores it.
3. **Preview/EOL signals are non-uniform.** Google: `status:"deprecated"` + `-preview` id. OpenAI: neither field — id substrings only. DeepSeek: no concept at all. Cross-provider stability checks must branch per provider.
4. **Preview models are the volatile rows.** `/preview/`+`/latest/` exclusions keep churn off the allowlist; consequence: a model existing only in `-preview` form is never admitted.
5. **Version-lock asymmetry:**
   - OpenAI locked to 5: `gpt-6` silently never appears until regex bumped (generalize to `/^gpt-\d+(\.\d+)?(-mini)?$/` if desired). Highest staleness risk.
   - DeepSeek forward-open on version (`v5`/`v6` auto-admit), locked on tier (`-max` rejected).
   - Google forward-compatible by construction (`gemini-4-flash/pro` auto-admit once stable) — most robust, contingent on Google keeping `family` consistent.
6. **`gpt-5.3` mainline does not exist** (only `-chat-latest`/`-codex`) — minor-version sequence has gaps.
7. **`cost` and `knowledge` are optional** (~7% openai, ~8-12% google lack `cost`). Price rendering must null-guard `cost`, `cost.cache_read`, `cost.tiers[]`/`cost.context_over_200k`.
