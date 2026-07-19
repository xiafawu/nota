# E2 — inline enrichment UI: user-reacted decisions

Mockup shown inline 2026-07-18 (three states: A un-summarized, B inline editing,
C confirm + in-flight); user verdicts per state. HTML source of the mock:
[mock.html](mock.html) (claude.ai-styled, layout/affordance fidelity — Swift
implementation restyles to the shipped polish grammar: unified glass cards,
collapsing header).

## Locked

- **State A (as mocked):** dashed placeholder card sits where the summary will render,
  between header and transcript — icon + "No summary yet" + one-line explainer +
  "Generate summary" and "Tags only" buttons side by side. Transcript fully readable
  below.
- **State B summary (as mocked):** dual entry into edit mode — explicit Edit button in
  the section header AND click-to-edit on the summary region. Esc cancels, ⌘Enter
  saves. "Edited" badge (accent pill) appears next to the section title once manually
  edited; Regenerate button sits beside Edit.
- **State B tags:** chips clean at rest; **× appears per-chip on hover only**; dashed
  "+ add tag" chip always visible at the end of the row (inline text field on click).
- **State C (keep both):** the confirm dialog ("Replace your edited summary? … Tags
  are kept and merged.") gates regeneration **only when the edited flag is set**
  (edited-is-protected, locked at charting). In-flight row shows spinner + "Generating
  summary — <model> · ~$<estimate>" + **Cancel** (abort = nothing written).
- **Dashboard:** transcript-only records get a **subtle "transcript" pill** on their
  Recent row; no row-level quick action — generation happens in the document view.

## Implementation notes for E4

- Placeholder card and summary section occupy the same layout slot — generate morphs
  placeholder → in-flight row → summary (single container, three states).
- Edited badge derives from the per-record edited flag(s) E3 defines — UI never
  tracks its own.
- Cost estimate in the in-flight row comes from `pricing.ts` rates × token estimate
  (E1 contract); display uses the T5 rule (`~` prefix, never invented precision).
