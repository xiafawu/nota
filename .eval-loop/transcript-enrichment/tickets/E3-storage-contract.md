<!-- wayfinder:grilling -->
# E3 — Storage & consistency contract for edits

status: closed (resolved 2026-07-18)
blocked-by: none (frontier)

## Question

Where do manual edits and on-demand generations live, and what keeps record, markdown
file, and UI consistent? Grilling, one decision at a time.

Decisions to resolve: (a) source of truth — HistoryRecord holds summary+tags, `.md`
rewritten from it via `write.ts` on every change (recommended), or `.md` is primary;
(b) edited-flag shape — per-field (`summaryEdited`, `tagsEdited`) vs record-level, and
whether `status` gains a value or stays `transcribed|completed`; (c) exact merge
semantics for tag regeneration under edited-is-protected (locked policy: generated ∪
manual — define dedup/casing/ordering); (d) does a summary generated on-demand flip
`status` to `completed` (and thus its dashboard appearance); (e) legacy records — those
without `contentHash`/usage entries still enrichable?; (f) failure atomicity — record
updated but `.md` write fails (or vice versa): ordering + recovery; (g) does duplicate
detection's summary-reuse path serve the *edited* summary (recommended: yes, record is
truth).

Deliverable: resolution table in this ticket; feeds E4.

## Resolution

Grilled 2026-07-18; all seven decided:

| # | Decision | Verdict |
|---|---|---|
| a | Source of truth | **HistoryRecord**; `.md` is a derived export, rewritten by `write.ts` on every change (hand-edits to the file are overwritten) |
| b | Edited flags | **Per-field** `summaryEdited` + `tagsEdited`; `status` union unchanged (edited is orthogonal to lifecycle) |
| c | Tag merge | **Lowercase-normalized union, manual first**: manual tags keep order, generated append, case-insensitive dedup, cap 8 |
| d | Status flip | On-demand summary → **`completed`**; dashboard "transcript" pill clears; dup-reuse then applies |
| e | Legacy records | **All enrichable** — only `transcriptText` is required and every record has it |
| f | Atomicity | **Record first, `.md` second**; `.md` failure → warn, next save rewrites (always regenerable from truth); never reverse order |
| g | Duplicate reuse | **Serves the edited summary** — record is truth, no special-casing |
