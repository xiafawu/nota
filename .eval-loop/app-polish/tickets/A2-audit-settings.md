<!-- wayfinder:research -->
# A2 — Audit: Settings window

status: closed (resolved 2026-07-18)
blocked-by: none (frontier)

## Question

What are the fit-and-finish defects in the Settings window (Cmd+, — model pickers,
masked API-key management, dictation settings) judged against Apple HIG's settings
conventions (System Settings, native `Settings` scene idioms) and the reference set?

Attention points: tab/section organization, control alignment and label grammar,
masked-key affordances, picker widths, window sizing/resizability, keyboard
navigation. Structure findings (sections that should merge/split) in scope.

Deliverable: `assets/A2-catalog.md`, same entry shape as A1 (screenshot, defect,
violated rule, fix direction, severity).

## Resolution

13 defects in [A2-catalog.md](../assets/A2-catalog.md): 0 jarring, 6 noticeable, 7
nitpicks — the settings window is structurally sounder than the main window (grouped
Forms everywhere, native toolbar material). Noticeable cluster: header/label duplication
in the Dictation form (Models tab already does it right), one fixed 720×480 frame for
all tabs, API Keys speaking raw env-var names with five always-armed input fields, two
permanently-disabled controls and developer telemetry (embedding dims, raw paths) in the
Speakers tab.

Deviations: only the Dictation tab was captured live — the active Space changed
mid-audit, synthetic clicks were halted (a few tab-clicks landed on the then-frontmost
Space; user informed), and General/Models/API Keys/Speakers were audited from code.
Screenshots deleted per privacy protocol. Live visuals of the four uncaptured tabs +
dark mode → W1 watch list. One earlier false finding corrected in-audit: Dictation tab
IS a grouped Form; cross-tab consistency is not a defect.
