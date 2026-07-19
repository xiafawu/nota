# ENRICHMENT-SPEC — transcript enrichment (locked)

Source of truth for implementation. Contracts locked in
[E1](assets/E1-contract.md) (generation), [E2](assets/E2-mockups/decisions.md) (UI),
[E3](tickets/E3-storage-contract.md) (storage). Three features: on-demand summary,
editable summary/tags, decoupled tag generation.

## Hard constraints (all lanes)

- **Record is truth** (E3-a): `HistoryRecord` holds summary+tags; the output `.md` is a
  derived export rewritten from the record on every change. Nothing parses the `.md`.
- **Edited-is-protected**: per-field `summaryEdited`/`tagsEdited` flags; regeneration
  over an edited field requires confirm; tag regen merges (lowercase union, manual
  first, cap 8) — never silently drops manual tags.
- **Empty LLM content is a failure** — throw, never write empty summary/tags over data.
- **User-facing CLI = generate verbs only** (`nota summarize <id>`, `nota tag <id>`).
  No user-facing edit verbs.
- Write ordering: **record first, `.md` second** (E3-f); `.md` failure warns and is
  repaired by the next successful save.
- No transcript-text editing; no bulk operations; dictation flow untouched.
- Match surrounding code style; tests updated in-lane when they assert changed behavior.

## Assembly decision (S1-scope, made here)

Swift persists edits/generations through a **hidden plumbing verb**, not by writing
history JSON or rendering markdown itself:
`nota history apply-enrichment <history-id> --json` (payload on stdin:
`{summary?, tags?, summaryEdited?, tagsEdited?}`). It updates the record (record-first),
rewrites the `.md` via the existing writer, prints the updated record JSON on stdout.
Rationale: keeps one markdown renderer and one atomicity implementation (TS), Swift
spawns it exactly like `UsageStatsProvider` spawns `usage --json`. Hidden from help —
does not violate "generate verbs only," which governs user-facing surface.

## CLI contract (Lane TS provides; Lane SWIFT consumes blind)

All verbs exit non-zero with a stderr message on failure; stdout is JSON only.

| Command | Effect | stdout |
|---|---|---|
| `nota summarize <history-id> [--force]` | Generate summary (E1 summary-only prompt when tags exist and are edited; full otherwise); flips status → completed; appends usage entry (`task:"summary"`); rewrites `.md`. `--force` required if `summaryEdited` (else exit 2 with message). | updated record JSON |
| `nota tag <history-id> [--force]` | Tags via E1 input ladder (summary text → transcript → ≤50k sampled excerpt); merge per E3-c unless `tagsEdited` and no `--force` (exit 2). Appends usage; rewrites `.md`. | updated record JSON |
| `nota history apply-enrichment <history-id> --json` (hidden) | Apply edits from stdin JSON; sets edited flags as given; record-first then `.md`. | updated record JSON |

Generation model = the **configured summary model** (E1); token cap 1024 for tags;
throw-on-empty via `parseTags`/`parseSummaryResponse` validation.

## Lane TS — pipeline, history, CLI

Files: `src/pipeline/summarize.ts`, `src/pipeline/history.ts`, `src/pipeline/write.ts`,
`src/cli/**` (new verb modules), `src/index.ts` (verb registration), `tests/**`.
- summarize.ts: `buildSummaryPrompt(…, {includeTags})`, `buildTagsPrompt`,
  `generateTags`, `summarizeOnly` (per E1 API shape); all through existing
  `callGPT`/`summaryTokenLimit`.
- history.ts: additive optional fields `summaryEdited?: boolean`,
  `tagsEdited?: boolean`; update helpers (set summary / set tags / apply-enrichment)
  implementing record-first ordering + status flip (E3-d) + tag merge (E3-c). Legacy
  records fully supported (E3-e). Duplicate-reuse path untouched (serves edited record
  by construction, E3-g).
- write.ts: expose a rewrite-from-record entry point the verbs call.
- Usage: `makeSummaryUsage` for both generate verbs (E1 — reuse `task:"summary"`).
- Tests (vitest): prompt builders include/exclude tags; parse validation throws on
  empty; tag merge semantics (union, manual-first, dedup, cap 8); apply-enrichment
  record-first ordering + flag setting; summarize/tag verb gating on edited flags
  (exit 2 without --force).

## Lane SWIFT — document view, dashboard, model

Files: `macos/Nota/UI/MainPaneView.swift`, `macos/Nota/UI/DocumentHeaderView.swift`,
`macos/Nota/UI/HomeDashboardView.swift`, `macos/Nota/App/NotaModel.swift` (+ its
history-entry decode wherever it lives), new `macos/Nota/UI/EnrichmentController.swift`
(process-spawn wrapper, mirroring `UsageStatsProvider` shape), Swift tests.
- State A (E2): summary-slot placeholder card on `status=="transcribed"` records —
  icon + "No summary yet" + explainer + "Generate Summary" / "Tags Only" buttons.
- Single-slot morph: placeholder → in-flight row (spinner + "Generating summary —
  <model> · ~$<estimate>" + Cancel) → summary section. Cost estimate from local
  pricing knowledge is OPTIONAL — if not cheaply available, show model name only
  (never invent a number; T5 display rule).
- State B (E2): summary section header with Edit + Regenerate buttons and an
  "Edited" accent badge (driven by record flags, never UI-local state); dual-entry
  edit (button + click-in), Esc cancels, ⌘Enter saves; tag chips with ×-on-hover,
  always-visible "+ add tag" chip with inline field.
- Confirm dialog (E2/E3): only when the target field's edited flag is set — copy:
  "Replace your edited summary? … Tags are kept and merged."
- Persistence: ALL mutations go through the CLI contract above (spawn
  `node dist/index.js …` with the UsageStatsProvider PATH/env pattern); Swift never
  writes history JSON or markdown. Cancel kills the process; nothing written.
- Dashboard (E2): subtle "transcript" pill on `status=="transcribed"` Recent rows;
  pill clears when the record completes. Invalidate usage cache after generation
  (spend appears in cost card).
- Respect shipped polish grammar (unified cards, collapsing header, hover rows).
- Swift tests: history-entry decode with/without new flags; placeholder-vs-summary
  state selection; confirm-required logic per flags; pill predicate.

**Parallel-safety:** Lane SWIFT codes against the CLI contract table verbatim (mock the
process layer in tests); it must not depend on Lane TS's actual implementation existing
in its worktree. Integration is verified post-merge.

## Verification

- Lane TS: `npm run build` + `npx vitest run` all green.
- Lane SWIFT: `npm run build:macos` exit 0; `cd macos && xcodegen generate &&
  xcodebuild test …` → `** TEST SUCCEEDED **` (both bundles).
- Post-merge (main session): full TS + Swift suites; deploy; live check — open a
  transcript-only record, generate summary, edit a tag, regenerate with confirm.

## Merge order

TS → SWIFT (contract provider before consumer), then follow-up integration commit if
either side drifted from the contract table. Deploy after both.
