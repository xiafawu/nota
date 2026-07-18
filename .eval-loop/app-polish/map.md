<!-- wayfinder:map -->
# Map: App-wide fit-and-finish polish

## Destination

A locked fit-and-finish spec covering **every user-facing surface** of the macOS app
(home dashboard, document/running views, Settings window, dictation HUD, menu bar,
onboarding/permission flows): each adjudicated defect with its agreed fix direction,
ready for Claude-direct implementation in per-surface PRs. No new features shipped by
this map — structure changes (view merges/splits) ARE in scope when a defect demands.

## Notes

- **Domain:** Nota (`xiafawu/nota`). Swift/macOS app; polish targets `macos/**` only.
- **Tracker:** local markdown (same as model-usage-stats effort; Linear writes blocked).
- **Plan, don't do:** tickets produce catalogs and verdicts, not code.
- **Locked decisions (charting session, 2026-07-18):**
  - Evidence = **both**: AFK screenshot audits first, then user live walkthrough fills gaps (motion, latency, feel).
  - Design authority = **Apple HIG base**; where HIG is silent (HUDs, dashboards), best-in-class macOS utilities: Raycast, Wispr Flow, Things, CleanShot.
  - Scope fence = **structure allowed**: spacing/type/color/motion/copy plus view merges/splits when audit justifies; still no new features.
  - Findings enter the spec only after user adjudication — audits propose, user disposes.
- **Skills:** audits use the synthetic-fn HUD capture technique (see memory `liquid-glass-floating-panel-trap`); adjudication uses `/grilling`.
- **HUD note:** dark-capsule design (PR #62) is a fresh, deliberate user decision — audit its *execution* (states, motion, sizing), not the dark-capsule direction itself.

## Execution

Claude direct (this session's model), worktree branches, per-surface PRs,
screenshot-verified iterations — chosen over omp because visual work needs the
capture-compare loop an implementer without eyes lacks. Foreground.

## Decisions so far

<!-- one line per closed ticket; detail lives in the ticket -->

- [A1 Audit: main window](tickets/A1-audit-main-window.md) — 17 defects ([catalog](assets/A1-catalog.md)); worst: transparent toolbar lets scrolled content collide with window chrome; clusters: inconsistent card materials, inert history rows, pinned document header clipping scroll, duplicating status pill, indeterminate run progress. Dark mode/resize/live-run deferred to W1.
- [A2 Audit: Settings window](tickets/A2-audit-settings.md) — 13 defects, none jarring ([catalog](assets/A2-catalog.md)); structurally sound (grouped Forms, native toolbar); fixes cluster on header/label duplication, fixed-height-for-all-tabs, env-var-speak + always-armed fields in API Keys, dead controls + debug telemetry in Speakers. Four tabs code-audited only → W1.
- [A3 Audit: dictation HUD live states](tickets/A3-audit-hud.md) — 12 defects, none jarring ([catalog](assets/A3-catalog.md)); clusters: wrong positioning anchor (Nota's own windows, not the dictation target), per-tick reposition fighting animations, linear RMS meter that underdrives and freezes, stale success/warning states that can resurrect the pill. Live driving vetoed (Space safety); 5 items → W1.
- [A4 Audit: menu bar + onboarding/permissions](tickets/A4-audit-menubar-onboarding.md) — 13 defects ([catalog](assets/A4-catalog.md)); jarring: full "Nota Dictation — Idle" text permanently in the menu bar (icon-only is the convention); noticeable: status menu missing Settings…, buttons that don't read as menu rows, latency telemetry in the menu, notarization jargon in onboarding copy. Popover state visuals → W1.
- [W1 User walkthrough: feel gaps](tickets/W1-user-walkthrough.md) — 2 defects, root-caused ([catalog](assets/W1-catalog.md)): missing home→document transition (animation lives below the swap site); jarring Speakers-tab chrome corruption (toolbar items merge into tab strip + sidebar material under chrome). Watch list unexercised — visual verification folds into implementation. Pool for D1: 57 findings.
- [D1 Adjudicate the combined defect catalog](tickets/D1-adjudicate-catalog.md) — 56 of 57 accepted (only S8 key-capture recorder deferred); nine cluster verdicts, all "fix"; shipping order Chrome → Dashboard → HUD → Settings → Menu bar, one screenshot-verified PR per surface.
- [S1 Assemble the polish spec](tickets/S1-assemble-spec.md) — [POLISH-SPEC.md](POLISH-SPEC.md): 56 findings in four file-fenced lanes (MAIN/HUD/SETTINGS/MENUBAR), per-lane build+test verification, merge order MAIN→HUD→SETTINGS→MENUBAR. **Map complete.** Implementation shipped 2026-07-18 via 4-lane parallel workflow: commits `73712d6` (main) `edc0d00` (hud) `8fc7633` (settings) `159dc08` (menubar) `c38526a` (follow-up); all lanes build+test green (120+48), deployed. Residual review nits recorded in the workflow output; only deferred finding: A2-S8.

## Not yet specified

- Per-surface fix directions — sharpen after adjudication; may split into per-surface decision tickets if verdicts disagree with audit recommendations.
- Whether structure-level findings (view merges/splits) add a navigation/IA decision ticket — sharpens after audits land.
- Cross-surface consistency system (shared spacing/type/color tokens in Swift) — only if audits find the surfaces drifting from each other, not just from the references.
- Motion standards (durations, curves, when to animate) — sharpens if audits flag inconsistent animation vocabulary.

## Out of scope

- New features of any kind — polish only.
- **Transcript enrichment features** (user-requested during W1, 2026-07-18; next effort candidate after polish ships): (1) on-demand summary generation from the document view — click → generate; (2) manual editing of summary and tags; (3) decoupled generation — tags without summary (today both come from one summarize pass). Touches pipeline + history schema + document UI; deserves its own map.
- App icon, About window, Developer ID notarization ("ship-grade" option declined at charting).
- Registry model refresh — separate effort (flagged on the usage-stats map).
- TypeScript CLI output polish — this effort is the macOS app.

## Tickets

| Ticket | Type | Status | Blocked by |
|---|---|---|---|
| [A1 Audit: main window (dashboard, document, running)](tickets/A1-audit-main-window.md) | research | closed | — |
| [A2 Audit: Settings window](tickets/A2-audit-settings.md) | research | closed | — |
| [A3 Audit: dictation HUD live states](tickets/A3-audit-hud.md) | research | closed | — |
| [A4 Audit: menu bar + onboarding/permissions](tickets/A4-audit-menubar-onboarding.md) | research | closed | — |
| [W1 User walkthrough: feel gaps](tickets/W1-user-walkthrough.md) | task | closed | A1, A2, A3, A4 |
| [D1 Adjudicate defect catalog](tickets/D1-adjudicate-catalog.md) | grilling | closed | W1 |
| [S1 Assemble polish spec](tickets/S1-assemble-spec.md) | task | closed | D1 |
