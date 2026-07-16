# PI Handoff — four Nota fixes (transcription-only, speaker-chip noise, speaker misID, LLM cross-check)

Self-contained. Assume no prior conversation. Repo: `/Users/xiafawu/Developer/Nota` (TypeScript CLI/pipeline under `src/`, native macOS SwiftUI app under `macos/Nota/`). Four independent fixes; **do them on one branch, but each as its own commit** so they can be reviewed separately. Branch off `master` (NOT `usage-stats-data-layer` or `nota-dictation-p1`).

## Fix A — transcription-only mode (`--no-summary`) [TypeScript, +small Swift]

Today the pipeline always runs the LLM summary stage. Add an opt-out.

- `src/index.ts`: add `.option("--no-summary", "Transcribe only; skip the LLM summary")` on the main command (mirror the existing `--no-diarize` / `--identify` wiring). Commander maps `--no-summary` to `options.summary === false`. Thread it through like `identify`.
- `src/config.ts`: add `summary?: boolean` (default true) to the resolved options type.
- `src/orchestrator.ts`: the summary stage is at ~line 352 (`emitPhase("summarizing")` → `summarizeTranscript(...)`); there is a second pipeline branch with the same call. When summary is disabled:
  - skip `summarizeTranscript`, leave the history record transcribed-but-unsummarized (the record already supports a transcribed status without a summary — see how a summary-model failure is handled today at ~329, "save transcript before summarization"),
  - write the output markdown as transcript-only (no summary/topics/actions sections),
  - do NOT emit usage for a summary that never ran.
- **macOS toggle (Swift, small):** add a "Transcribe only (skip summary)" toggle in `macos/Nota/UI/SettingsView.swift` (or the run options surface) that passes `--no-summary` when the app invokes the CLI. If the app's CLI-arg construction is not obvious, implement the CLI flag fully and leave a clearly-marked TODO for the Swift wiring rather than guessing.
- Tests: a pipeline/CLI test that `--no-summary` produces a transcript-only record + output and makes no summary API call.

## Fix B — drop redundant `Name → Name` in speaker chips [SwiftUI, tiny]

`macos/Nota/UI/SpeakerChipsView.swift:45` renders `"\(label) → \(name)"` always, so when the diarized label already equals the identified name the chip shows a pointless `X → X`.

- When `!name.isEmpty && name == label`, render just `name` (no arrow). Keep `"\(label) → ?"` for unidentified and `"\(label) → \(name)"` only when they genuinely differ. Check the other render site at ~line 138 (`Text("\(chip.label) →")`) for the same collapse.

## Fix C — cross-context speaker false-positive [TypeScript, the substantive one]

Symptom: a speaker who is **not enrolled** in the current recording's context gets matched to a **different** enrolled person (an open-set false-positive — the matcher forces the nearest name instead of returning "unknown"). Corrupts notes by mislabeling.

Root causes to address in `src/pipeline/embed.ts` + `src/pipeline/speakers.ts`:
1. **Threshold too low.** `MATCH_THRESHOLD = 0.5`, `TENTATIVE_THRESHOLD = 0.35` (`src/pipeline/embed.ts:4-5`). 0.5 cosine is loose for WeSpeaker d-vectors and admits cross-speaker matches. Raise the confident bar (try `MATCH_THRESHOLD = 0.65`; tentative `~0.5`) — but make these tunable (see below), don't just swap constants blindly.
2. **No margin / open-set rejection.** `rankMatches` (`src/pipeline/speakers.ts:110`) takes the top score ≥ threshold. Add a **margin gate**: only claim a name if `top1 - top2 >= MARGIN` (e.g. 0.06) AND `top1 >= MATCH_THRESHOLD`; otherwise leave the label unidentified (raw `Speaker N`). This is what stops an unenrolled speaker from being absorbed into the nearest profile.
3. **Make thresholds overridable** via env or settings (e.g. `NOTA_MATCH_THRESHOLD`) so the user can tune without a rebuild; keep the raised values as defaults.

- Tests: unit tests over `rankMatches` — (a) an unenrolled embedding near one profile but below the stricter bar → no match; (b) an ambiguous embedding within `MARGIN` of two profiles → no match; (c) a clear match still resolves.
- **Cannot fully validate here:** accuracy depends on the user's real voiceprints/audio. Implement the guardrails + tests; the user validates on their recordings. Say so in the commit.

## Fix D — LLM cross-check on voiceprint speaker labels [TypeScript]

Motivation: the acoustic voiceprint matcher (Fix C's subject) can assign a **wrong enrolled name** to a speaker — content then contradicts it (e.g. the labeled person is clearly acting in a different role than that name ever does, or the other speaker addresses them differently). The LLM reads the transcript and acts as a **veto**, not a second guesser.

**Locked policy — demote + flag, never override:**
- The LLM NEVER asserts or substitutes a name. On conflict it strips/demotes the doubted voiceprint name; it must not replace it with its own inference.
- Output per diarized label: `{ label, verdict: "consistent" | "conflict" | "insufficient-evidence", role?: string, evidence?: string }` where `evidence` is a short verbatim quote from the transcript supporting a conflict verdict. `role` is a generic role word inferred from content ("interviewer", "therapist", "customer") — display-only context, never persisted as an identity.
- On `conflict`: demote that label's match to **tentative** (reuse the existing tentative flow — `MatchResult.tentative` in `src/pipeline/speakers.ts`) so the existing confirmation path surfaces it; annotate with the evidence quote. On `insufficient-evidence` or `consistent`: leave the voiceprint result untouched.

**Entity profiles (the veto's priors).** A bare veto can only catch *internal* contradictions, which most transcripts lack. Give it a stored semantic profile per enrolled speaker:

- Extend the speaker store (`~/.nota/speakers.json`, `src/pipeline/speakers.ts`): add optional `description?: { text: string; updatedAt: string; sourceHistoryIds: string[] }` per profile. Additive/back-compat — profiles without it behave as today, and the veto falls back to internal-consistency-only for speakers lacking a description.
- `text` is a short LLM-generated entity description (1–3 sentences: typical role, recurring topics, speaking style) built from transcript excerpts of sessions where this speaker's identity is human-confirmed.
- **Write gate — poisoning is the failure mode this feature exists to fix, so NO unsupervised writes.** Descriptions are created/updated ONLY by:
  1. **Enrollment** — when the user names/enrolls a speaker (that session is human-confirmed by definition), generate the description from that session's transcript.
  2. **Manual refresh, CLI** — new verb `nota speakers describe <name>` (follow the existing `src/cli/speakers.ts` command patterns): regenerates the description from that speaker's segments across history records where the name was confidently assigned; `--from <history-id...>` to restrict sources. Confirmation to stderr, stdout scriptable, non-zero exit on missing profile.
  3. **Manual refresh, macOS UI** — a small "Refresh description" button per speaker row in `macos/Nota/UI/SpeakersSettings.swift` (plus display of the current description text + updatedAt), invoking the same regeneration path the CLI verb uses. Follow how that view already invokes speaker operations; if the Swift↔CLI bridge for this is not obvious, implement the CLI verb fully and leave a clearly-marked TODO for the button wiring rather than guessing.
- A `conflict` verdict must NEVER trigger a description update (that session is exactly the untrusted kind).

Implementation:
- New `src/pipeline/verify-speakers.ts`: takes the speaker-labeled transcript + the voiceprint match results + each matched speaker's `description` (when present), makes ONE cheap LLM call (reuse the resolved summary model + OpenAI-compatible client from `src/pipeline/summarize.ts`; strict JSON output). Prompt must instruct: judge whether each labeled speaker's content is consistent with their stored description AND internally consistent; quote evidence; do not guess names.
- New `src/pipeline/describe-speaker.ts` (or colocate in speakers.ts): the description-generation call shared by enrollment, the CLI verb, and the UI button.
- Wire into the orchestrator's identify path: runs only when `--identify` produced at least one confident (non-tentative) name match AND a summary-capable model/key is available. Sum its tokens into the run's summary-model usage if trivially possible; otherwise leave a TODO (do not restructure the usage layer for this).
- Gating: `--identify` implies the cross-check by default; `--no-verify-speakers` opts out. If the run is `--no-summary` AND the user opted out of LLM calls, skip silently (privacy: this feature does send transcript text to the LLM API — one more reason the veto must stay optional).
- The demotion must reach the UI: a demoted chip falls back to the existing tentative/unnamed rendering (`label → ?`) rather than showing the doubted name.
- Tests: mock the LLM call — (a) conflict verdict demotes a confident match to tentative with evidence attached; (b) consistent verdict changes nothing; (c) malformed/failed LLM response = no-op (fail open, never blocks the pipeline); (d) `--no-verify-speakers` skips the call; (e) veto works description-less (internal-consistency only) for profiles without `description`; (f) enrollment writes a description, a conflict session never does; (g) `nota speakers describe` regenerates and stamps `updatedAt`/`sourceHistoryIds`; store round-trips profiles with and without `description`.

## Hard constraints

- Do NOT touch the usage/cost data layer (`src/pricing.ts`, `src/usage-stats.ts`, the `usage?` fields) — that's a separate in-flight branch.
- Keep everything back-compatible: existing history records and enrolled speakers must load unchanged.
- Don't lower any threshold; only raise / gate.

## Verify

- `npm run build` clean, `npm test` green (new tests included).
- A: a `--no-summary` run yields transcript-only output + record, zero summary API calls.
- B: build the macOS app or eyeball the two chip render sites — equal label/name shows just the name.
- C: the three `rankMatches` tests pass; default thresholds are the raised values; env override works.
- D: mocked-LLM tests pass; a conflict demotes to tentative (never renames) and never updates a description; LLM failure is a silent no-op; flag opt-out works; `nota speakers describe <name>` regenerates; SpeakersSettings shows description + refresh button (or a clearly-marked TODO for the Swift wiring).
- `git status`: four commits, TS + the one SwiftUI file only; nothing under `src/pricing.ts` / `src/usage-stats.ts`.
