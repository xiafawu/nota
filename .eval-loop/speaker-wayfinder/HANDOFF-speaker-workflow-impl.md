# HANDOFF: Speaker workflow implementation (map XIA-406 — all decisions locked)

Self-contained. Assume no prior conversation. Repo: `/Users/xiafawu/Developer/Nota`.
Branch **off `master`**. Avoid any `worktree-agent-*` branches if present. Read
`CLAUDE.md` first — it is the spec of record for existing behavior; you will
also update it (see Task 4).

## Context

Nota transcribes + diarizes audio (TS CLI in `src/`, macOS app in `macos/`).
Speaker identity: ONNX WeSpeaker d-vectors (`src/pipeline/embed.ts`), store
`~/.nota/speakers.json` v4 (`src/pipeline/speakers.ts`), cosine MATCH ≥ 0.65 /
TENTATIVE ≥ 0.5, identify currently opt-in (`--identify`) and tentative
confirms TTY-gated in `src/orchestrator.ts`. `nota history rename-speaker`
(`src/pipeline/history.ts` `renameRecordSpeaker`) and app chip rename+enroll
already ship. A wayfinder effort (Linear XIA-406, tickets XIA-407…412) locked
the design below; the measurement behind it is
`docs/research/voiceprint-cosine-bands.md`. This handoff is the whole
implementation.

## Hard constraints (do-NOT-touch fence)

- Thresholds stay 0.65 / 0.5. No per-speaker thresholds, no threshold learning.
- NO auto-enrollment from confident (≥0.65) matches. NO auto-regeneration of
  summaries. NO blocking gate before summary.
- Do not touch `macos/Nota/Dictation/**` (dictation is a separate in-flight
  surface), `scripts/research/**`, `docs/research/**`, `.eval-loop/**`.
- `~/.nota/speakers.json` stays schema **v4** — new fields optional + tolerant
  decode on BOTH the TS and Swift sides (one damaged/unknown field must never
  wipe a store or a picker; follow the dictionary-store precedent in CLAUDE.md).
- History record JSON: additive fields only; records without them must load
  unchanged (legacy records simply have no suggestions).
- Secrets/keys untouched. No new npm dependencies.

## Locked decisions (not re-openable; source: Linear XIA-407…412 resolutions)

1. **Identify-by-default.** Recognition auto-runs on every diarized
   transcription whenever the store has ≥1 enrolled speaker — CLI and app.
   `--no-identify` (CLI flag) and a matching app setting opt out; `--identify`
   still forces (zero-voiceprint case). First-run ONNX download proceeds with a
   one-line notice (CLI stderr / app progress); failure no-ops identity with
   the existing message.
2. **Clips always captured.** Every diarized run saves per-speaker PCM clips
   under `~/.nota/history/<id>.assets/`, whether or not recognition matched.
   Clips live exactly as long as their history record (deleted with it);
   `--no-history` stores nothing.
3. **Tentative candidates persist on the history record.** For each diarized
   label with best cosine in [0.50, 0.65): store `{label, suggestedName,
   score, voiceprintId}` plus decision state. Confident matches (≥0.65)
   auto-label as today.
4. **App surfacing: the speaker chip.** A pending suggestion renders on the
   chip ("Speaker 2 → Kenny Kim? 0.62") with accept/dismiss. Accept = the
   existing rename propagation (segments, clip, output `.md`) AND enroll that
   record's clip as a new voiceprint for the person. Dismiss = clear on this
   record only; store untouched.
5. **Advisory summary gate.** Summary always runs immediately. Unnamed
   (`Speaker N`) chips carry a subtle unnamed-state; after any rename/accept on
   a record whose summary exists, a one-click "Regenerate summary" affordance
   appears until used or dismissed. The CLI's existing TTY prompt before
   summary stays as-is.
6. **Enrollment hygiene.** Enrollment happens only by human action (accept,
   chip rename+enroll, CLI verbs). At enroll time, compare the new embedding
   against the person's existing prints: strong disagreement warns (naming the
   number) and marks the print `lowAgreement: true` — never refuses, never
   silent. `nota speakers doctor` lists low-agreement prints and same-name
   pairs below 0.30, suggesting delete/reassign via existing verbs; the app's
   speakers view shows the same flags (read-only badge is enough).
7. **CLI suggestions surface.** `nota history suggestions` — pending
   suggestions as tab-separated rows on stdout (record id, label, suggested
   name, score), header on stderr. `nota history accept-suggestion <id>
   <label>` / `nota history dismiss-suggestion <id> <label>` apply decision
   semantics from (4). `nota history suggestions --recompute <id>` recomputes
   suggestions for an old record from its stored clips against today's store
   (on-demand backfill; no migration sweep). Confirmations to stderr, stdout
   scriptable, missing record/label exits non-zero — house style.

## Task + lane manifest

**Lane A (sequential, first — it owns the shared schema):** TS pipeline +
stores. Auto-identify policy + `--no-identify`; always-capture clips;
suggestion computation + persistence on the history record; enrollment
consistency check + `lowAgreement` flag in the speaker store; download notice.
Files: `src/orchestrator.ts`, `src/pipeline/{speakers,history,embed}.ts`,
`src/index.ts` (flag), `src/config.ts` if needed, tests under `tests/`.

**Lane B (parallel-safe after A; owns `src/cli/**` + `src/index.ts` verb
wiring):** the CLI verbs from decision 7 + `nota speakers doctor` (decision 6).
Reuse `renameRecordSpeaker` and the enroll path; do not duplicate them.

**Lane C (parallel-safe after A; owns `macos/Nota/App/**` + `macos/Nota/UI/**`
EXCEPT dictation):** chip suggestion UI (accept/dismiss), unnamed-state, the
regenerate-summary affordance, identify app setting, speakers-view
low-agreement badge. App runs the TS pipeline via `nota-app-run.sh`, so Lane A
lands the data; the app reads record JSON + speakers.json (tolerant decode).

One commit per lane minimum, message style matching `git log` (feat(...): lower-case
sentence). B and C may be one agent each or one agent total — do not split
further; the file sets above are the ownership fence.

## Stop-fence

THIS SPEC ONLY. Do not refactor diarization, do not touch dictation, do not
redesign the speakers store beyond the named additive fields, do not add
settings beyond the identify toggle, do not implement per-speaker thresholds
"while you're in there."

## Verify (all required; named tests are part of the fence)

- `npm test` — full vitest suite green, INCLUDING new tests you must add and
  name in your reply: suggestion computation bands (0.49/0.50/0.649/0.65
  boundary cases), suggestion persistence + accept/dismiss round-trip on a
  temp history dir, enrollment-consistency flagging, doctor output, legacy
  record (no suggestions field) loads unchanged.
- `npm run build:macos` prints `** BUILD SUCCEEDED **` (Lane C touches
  `macos/**`; a TS suite says nothing about Swift).
- Full Swift tests: from `macos/` run `xcodegen generate` then
  `SWIFT_BACKTRACE=enable=no xcodebuild test -project Nota.xcodeproj -scheme
  Nota -destination 'platform=macOS'`. Trust only a trailing
  `** TEST SUCCEEDED **`; grep the log for `Fatal error|Restarting` (crashed
  hosts hide failures). Known environmental flake on this machine:
  FocusedTargetTests/PasteInjector host crash — verify against clean master
  before attributing to yourself.
- Smoke (real output in your reply): `node dist/index.js history suggestions`
  on a temp `NOTA_*`-pointed store; `node dist/index.js speakers doctor`
  against a fixture store containing a 0.025-agreement pair.
- `git diff master...<branch> --stat` contains nothing from the do-NOT-touch
  list.

### Task 4 (part of Lane A's commit or its own): docs

Update CLAUDE.md's speaker sections (flags, Speaker Management, Key Design
Decisions) to describe the new behavior in the file's existing voice —
amend, don't rewrite history.

## Required reply template

Reply using exactly these sections:
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine/data)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
