<!-- wayfinder:map -->
# Map: Transcript enrichment (on-demand summary, editable summary/tags, decoupled tags)

## Destination

A locked spec (polish-effort shape: adjudicated decisions, file-fenced lanes) for the
three user-requested enrichment features: (1) on-demand summary generation from the
document view, (2) manual editing of summary and tags, (3) tag generation decoupled
from summary generation. Ready for Claude-direct workflow implementation.

## Notes

- **Domain:** Nota — TS pipeline (`src/pipeline/summarize.ts`, `history.ts`, `write.ts`)
  + Swift document view (`MainPaneView`, `DocumentHeaderView`, `NotaModel`).
- **Tracker:** local markdown (same convention as app-polish).
- **Plan, don't do** — tickets decide; the spec ships nothing.
- **Ground truth (verified 2026-07-18):** `HistoryRecord` stores full `transcriptText`
  with status `"transcribed" | "completed"` — summary-less records already exist
  (Transcribe-only / `--no-summary`). Tags are parsed from a `### Tags` section of the
  single summarize response (summarize.ts:140) — decoupling requires a new extraction
  path. Output `.md` is derived from the record by `write.ts`.
- **Locked at charting (2026-07-18):**
  - Destination = locked spec, **Claude-direct workflow** implementation (polish precedent).
  - Edit UX direction = **inline in document view** (tag chips add/remove in place,
    summary edit affordance) — E2 prototypes the specifics.
  - Regeneration policy = **edited-is-protected**: manual edits set an edited flag,
    Regenerate confirms before overwriting, tag regeneration merges (generated ∪ manual),
    never silently drops manual tags.
  - CLI = **generate verbs only** (`nota summarize <history-id>`, `nota tag <history-id>`);
    editing is macOS-only.
- **Skills:** `/grilling` (E3), `/prototype` (E2). One ticket per session; claim via
  `status: in-progress`.

## Execution

Claude direct (session model), file-fenced parallel workflow lanes (TS pipeline/CLI vs
Swift UI), full TS + Swift test gates, screenshot verification for the UI lane.

## Decisions so far

<!-- one line per closed ticket; detail lives in the ticket -->

- [E1 Split-generation contract](tickets/E1-split-generation.md) — configured summary model for all ops (key availability beats hardcoded-cheap); tags = one-line-reply prompt, 1024 cap, throw-on-empty; input ladder summary-text → transcript → sampled excerpt; usage reuses `task: "summary"` (zero schema ripple). [Contract](assets/E1-contract.md).
- [E2 Prototype: inline enrichment UI](tickets/E2-ui-prototype.md) — placeholder card with both generate actions in the summary slot; dual-entry summary edit (button + click-in, Esc/⌘Enter) with Edited badge; tag × on hover + "+ add tag" chip; confirm only when edited; in-flight row shows model + ~cost + Cancel; dashboard marks summary-less rows with a subtle "transcript" pill. [Decisions](assets/E2-mockups/decisions.md).
- [E3 Storage & consistency contract](tickets/E3-storage-contract.md) — record is truth (.md derived, rewritten every change); per-field summaryEdited/tagsEdited flags; tag merge = lowercase union manual-first cap 8; on-demand summary flips status to completed; all legacy records enrichable; record-first-then-md atomicity; dup-detection serves edited summaries.
- [E4 Assemble the enrichment spec](tickets/E4-assemble-spec.md) — [ENRICHMENT-SPEC.md](ENRICHMENT-SPEC.md): TS lane provides a verbatim CLI contract (summarize/tag + hidden apply-enrichment plumbing verb), Swift lane consumes it blind; merge TS → SWIFT. **Map complete.** Shipped 2026-07-19: commits `259218a` `99b366d` (TS), `17cefa8` (Swift, hand-merged over polish — its worktree had a stale pre-polish base), `e0f0c09` (applyEdit epoch guard from review). Gates: 352 TS + 77/120 Swift tests green; deployed. Live validation (real generate on a transcribed record) = user.

## Not yet specified

<!-- fog cleared: dashboard surfacing resolved by E2 (subtle "transcript" pill) -->

## Out of scope

- Editing the transcript text itself — enrichment covers summary + tags only.
- Bulk/batch re-summarization or re-tagging across history.
- Other enrichment types (translation, action-item sync, calendar links).
- Dictation flow — enrichment applies to transcription records only.

## Tickets

| Ticket | Type | Status | Blocked by |
|---|---|---|---|
| [E1 Split-generation contract: prompts, models, cost](tickets/E1-split-generation.md) | research | closed | — |
| [E2 Prototype: inline enrichment UI in document view](tickets/E2-ui-prototype.md) | prototype | closed | — |
| [E3 Storage & consistency contract for edits](tickets/E3-storage-contract.md) | grilling | closed | — |
| [E4 Assemble enrichment spec](tickets/E4-assemble-spec.md) | task | closed | E1, E2, E3 |
