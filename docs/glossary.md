# Glossary

Terms that carry a decision. Each entry says what the term means, where it is
realized in code, and which ADR or ticket settled it — so the word can be
quoted rather than recalled.

Add a term here when its meaning has been *decided* and getting it wrong would
put code in the wrong place. Do not add terms that are merely domain nouns with
an obvious reading.

---

## global chrome

Controls that act **across all transcripts, or on the app itself**. They live
on the window toolbar's trailing edge and are present regardless of which
record — if any — is open.

Today: **History** (the drawer, ⌘L) and **Settings**.

- Realized in: `macos/Nota/UI/ContentView.swift` — the `ToolbarItem`s at
  `.primaryAction` and the History command.
- Settled by: [ADR 0005](adr/0005-global-vs-local-chrome.md).
- Contrast with [local chrome](#local-chrome).

## local chrome

Controls that act on **the transcript currently in front of the owner**. They
live in the **content area's** bottom-right corner as individual floating round
buttons — not on the window toolbar, and not as a labelled bar.

Today: **Summary** and **Share**.

Two boundaries the term does *not* cover:

- **Metadata is not an action.** Speaker chips and tags are per-transcript but
  display state, so they stay in `DocumentHeaderView` at the top of the content
  area. An *action* on them belongs bottom-right — except an action that is the
  action *of the thing displayed*, which attaches to its object (generate-tags
  sits on the tag row).
- **Corners of the content area, not of the window.** The toolbar is the app's
  chrome; bottom-right is the document's. A local control is inset from the
  content area's edges, never pinned to the window frame.

- Realized in: `macos/Nota/UI/MainPaneView.swift` — the bottom-right cluster.
- Settled by: [ADR 0005](adr/0005-global-vs-local-chrome.md), with the
  button-state model from XIA-416.
- Contrast with [global chrome](#global-chrome).
