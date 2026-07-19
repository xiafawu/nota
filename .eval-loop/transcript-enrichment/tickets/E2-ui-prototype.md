<!-- wayfinder:prototype -->
# E2 — Prototype: inline enrichment UI in document view

status: closed (resolved 2026-07-18)
blocked-by: none (frontier)

## Question

What exactly does inline enrichment look like in the document view (direction locked:
inline, not an edit sheet)? HITL — build cheap SwiftUI mockups (screenshots or a
disposable branch), user reacts.

Must cover: (a) `status: "transcribed"` record opened — where "Generate Summary" /
"Generate Tags" actions sit and what the summary-less body looks like; (b) tag chips —
add (+ chip? text field?) and remove (hover ×? click?) in place; (c) summary editing —
what the affordance is (hover pencil, click-to-edit region, Done/Escape semantics)
against the RichTextViewer-rendered body; (d) the edited badge and the
Regenerate-confirm moment (edited-is-protected policy is locked; visualize it);
(e) in-flight generation state (spinner placement, cancel?).

Constraint: respect the just-shipped polish grammar (collapsing header, unified card
materials, hover-row conventions). Mockups only — no pipeline wiring.

Deliverable: `assets/E2-mockups/` images + a short decisions note; unresolved reactions
become the discussion input for E4.

## Resolution

Mockup shown inline (three states), all five zones reacted:
[decisions.md](../assets/E2-mockups/decisions.md). Locked: placeholder card with both
generate actions in the summary slot; dual-entry summary editing (Edit button +
click-to-edit, Esc/⌘Enter) with an Edited badge; tag chips ×-on-hover + always-visible
"+ add tag"; confirm dialog only when edited (tags merged, never dropped); in-flight
row with model + ~cost + Cancel. Bonus fog cleared: dashboard shows a subtle
"transcript" pill on summary-less Recent rows (no row-level quick action).
Deviation: mockup medium was an inline HTML widget rather than SwiftUI screenshots —
faster reaction loop; layout/affordance decisions transfer, visual styling defers to
the shipped polish grammar.
