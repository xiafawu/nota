<!-- wayfinder:grilling -->
# E3 — Storage & consistency contract for edits

status: open
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
