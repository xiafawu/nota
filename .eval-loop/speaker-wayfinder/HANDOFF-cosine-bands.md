# HANDOFF: Measure the voiceprint cosine bands on real data (XIA-407)

Self-contained. Assume no prior conversation. Repo: `/Users/xiafawu/Developer/Nota`.
Branch **off `master`**. Do not touch any `worktree-agent-*` branches if present.

## Context

Nota is a TypeScript CLI (plus a macOS app) that transcribes and diarizes audio.
Speaker identity is a pure-Node ONNX pipeline: `onnxruntime-node` runs the
WeSpeaker ResNet34-LM model over Kaldi-fbank features computed in JS, and
enrolled speakers are matched by cosine similarity of L2-normalized d-vectors.
The thresholds in production are MATCH ≥ 0.65 and TENTATIVE ≥ 0.5
(`src/orchestrator.ts` / `src/pipeline/speakers.ts` — read the code for the
exact constants and where they gate). A real near-miss motivates this ticket:
the owner's colleague Kenny scored 0.623 against his enrolled voiceprint —
tentative band, silently dropped in app (no-TTY) runs.

This is a **research ticket** on the speaker-workflow wayfinder map (XIA-406).
It produces a measurement report, not a behavior change.

## Hard constraints (do-NOT-touch fence)

- NO modifications to any existing file: `src/**`, `macos/**`, `tests/**`,
  `scripts/*` (existing files), `package.json`, `CLAUDE.md`.
- New files ONLY under `scripts/research/` and `docs/research/`.
- `~/.nota/**` is **read-only**. Never write to `speakers.json`, the history
  store, or any asset. Never delete or move a clip.
- Do not print or commit raw embedding vectors (summaries/statistics only).
- No new npm dependencies.

## Locked decisions

| Decision | Locked value |
| --- | --- |
| Embedding pipeline | Reuse the existing helpers in `src/pipeline/embed.ts` (import them; do not reimplement fbank/ONNX) |
| Data sources | Enrolled voiceprints in `~/.nota/speakers.json` (v4) + every per-speaker clip under `~/.nota/history/*.assets/*.pcm` |
| Clip format | Whatever `src/pipeline/embed.ts`/`speakers.ts` say it is — read the code, do not guess sample rate or encoding |
| Deliverables | `scripts/research/cosine-bands.ts` (rerunnable) + `docs/research/voiceprint-cosine-bands.md` (the report) |
| Report owner-question | A clear verdict: keep 0.65/0.5, move them (to what), or recommend per-speaker bands — with the distributions that justify it |

## Task (single lane, sequential — shared data, one agent)

1. Read `src/pipeline/embed.ts`, `src/pipeline/speakers.ts`, and the identity
   sections of `CLAUDE.md` to learn the exact store schema, clip format, and
   similarity function.
2. Write `scripts/research/cosine-bands.ts` (run with `npx tsx`):
   - Load every enrolled voiceprint (name, voiceprint id, embedding).
   - Embed every history clip via the existing embed helpers (skip unreadable
     clips with a counted warning; never crash the sweep on one bad file).
   - Compute cosine similarities: clip↔enrolled-voiceprint (labeled by whether
     the history record's segments say that clip's speaker was later named the
     same person, where determinable from `~/.nota/history/*.json`), and
     enrolled↔enrolled.
   - Emit summary stats + ASCII histograms of intra-speaker vs inter-speaker
     distributions, min/max/quantiles, and every pair that lands in
     [0.5, 0.65).
3. Write `docs/research/voiceprint-cosine-bands.md`:
   - Methodology (what was compared, N of clips/voiceprints, exclusions).
   - Distributions (tables + ASCII histograms), where 0.623 sits.
   - Sensitivity: how similarity moves with clip duration if the data shows it.
   - **Verdict** per the locked decision above, stated for a reader deciding
     UX trust levels (map tickets XIA-408/XIA-411 consume this).
4. Commit script + report on your branch (message style: `docs(research): …`).

## Stop-fence

THIS MEASUREMENT ONLY. Do not change thresholds, do not touch the pipeline,
do not build UI, do not start XIA-408/409/410/411, do not edit the store.

## Verify

- `npx tsx scripts/research/cosine-bands.ts` exits 0 and prints the summary
  (paste real output into the report's appendix and into your reply).
- `npm test` — full TS suite still green (`Test Files … passed`); you changed
  no source, so any failure is pre-existing — say so if seen.
- No `macos/**` in `git diff master...<branch> --stat` (fence check; Swift gate
  not applicable).
- The report file exists and renders as plain markdown (no HTML).

## Required reply template

Reply using exactly these sections:
## Branch & commits        (branch name, one line per commit)
## Per-lane outcomes       (what each lane/fix delivered)
## Verification evidence   (commands run + REAL output, not summaries)
## Deviations from spec    (anything skipped, worked around, or changed — say so plainly)
## Cannot-verify-here      (what needs the user's machine/data)
## Orchestrator signals    (state changes, what this unblocks, suggested next dispatch —
                            written for a FRESH orchestrator session)
