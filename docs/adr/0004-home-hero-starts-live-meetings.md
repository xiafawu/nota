# 0004 — Home hero starts live meetings; single record entry, preflight-gated

Date: 2026-08-01
Status: accepted

## Context

The toolbar mic toggle (`ContentView.liveMeetingButton`) was the only start
entry for live meetings, present in every non-running phase, and it bypassed
the preflight gate entirely — `PreflightOverall.fail` is documented as "blocks
recording if blocking", yet a blocked user could still force-start a session
that then failed later with an error banner. The home hero ("Ready to record"
verdict card) was a status label only: informative, not actionable.

## Decision

The home hero's left cluster — status dot, verdict title, and subtitle — is
the **record entry**: clicking it starts a live meeting.

- Gating follows the verdict: `Ready` and `Unverified` start a session
  (matching the existing copy "You can record, but a run may fail"); `Blocked`
  renders inert, with the failing check already shown above the fold. This
  finally enforces the documented preflight gate.
- The toolbar mic button is removed from every phase. **Home is the only
  start entry** — with a transcript open, starting a recording means going
  Home first. No record affordance is added to the document view.
- Stop lives solely in the live pane header (`LiveMeetingView.stopControl`);
  no toolbar stop control is kept.

Chosen interactively on the Trace walk (`.trace/planner.json`, project Nota,
root `n_rec_root`).

## Considered Options

- **Dedicated "Start Recording" button** in the hero, verdict text stays a
  status label — clearer affordance, but the click target diverges from the
  copy the user pointed at.
- **Whole hero card clickable** — forces the Re-check button out of the card,
  an extra layout change for no gain.
- **Record affordance in the document view** — keeps two entry points alive
  and contradicts the toolbar removal in spirit.
- **Toolbar stop-only while recording** — recreates the removed control for a
  stop the pane already owns.

## Consequences

- A `Blocked` verdict can no longer be force-started; the failure surfaces as
  a preflight issue instead of a doomed session.
- Starting a new meeting while reading a transcript is two clicks (Home →
  hero) instead of one.
- The live pane's idle "Start Recording" button remains the retry path after
  a failed session (phase stays `.liveMeeting` on `.failed`).
