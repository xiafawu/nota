# A2 defect catalog — Settings window

Audit date: 2026-07-18, deployed build from master `fe0ac0f`, light mode, 720×568 window.
Method: live captures of the Dictation tab (window-id screencapture); General, Models,
API Keys, and Speakers tabs audited from code — mid-audit the active macOS Space changed,
so synthetic tab-clicks were halted for safety (see Deviations in the ticket).
Code: `SettingsView.swift` (General/Models/API Keys), `DictationSettingsView.swift`,
`SpeakersSettings.swift`.

**What's already right:** every tab uses `.formStyle(.grouped)` — cross-tab layout is
consistent (an earlier visual read suggesting otherwise was wrong); model menus group by
provider; key values are masked with env/config source badges; destructive delete has a
confirmation alert; the settings toolbar keeps its native material (no A1-style chrome
collision here).

Severity scale: **jarring** / **noticeable** / **nitpick**.

---

## Layout & structure

### S1 · noticeable · Section header repeats the control label (Dictation tab)
"Activation" renders as section header AND picker label 40pt apart
(DictationSettingsView.swift:29–36); same for "Trigger Key" (47–64). The Models tab shows
the right pattern — section header carries the label, picker is `.labelsHidden()`
(SettingsView.swift:108–119). One window, two conventions.
**Fix direction:** adopt the Models pattern in the Dictation form.

### S2 · noticeable · One fixed 720×480 frame for all tabs
`TabView.frame(width: 720, height: 480)` (SettingsView.swift:38). Dense tabs (Dictation)
scroll; sparse tabs (General: two toggles) sit in mostly blank space. System Settings
resizes per pane.
**Fix direction:** per-tab ideal height, fixed width.

### S12 · nitpick · Privacy disclosure styled as a control section
Three caption lines get their own header + card (DictationSettingsView.swift:127–143),
visually equal to sections holding actual controls.
**Fix direction:** render as the footer of the Polish section.

## API Keys tab

### S3 · noticeable · Raw env-var names as primary labels
Rows lead with `ASSEMBLYAI_API_KEY` etc. (SettingsView.swift:183). HIG: speak the user's
language — "AssemblyAI", with the env var as caption.

### S4 · noticeable · Every key shows an always-armed input
Each of the five rows renders an empty "Paste to set" SecureField + Save even when a key
is already configured (SettingsView.swift:189–200) — implies action needed and quintuples
form noise.
**Fix direction:** status row per provider; field appears on "Replace…".

### S11 · nitpick · No way to remove a key
Set/replace only; removal requires hand-editing `~/.nota/config`.

## Speakers tab

### S5 · noticeable · Permanently disabled controls
Toolbar "New" is disabled forever ("Reserved for future enrolment flow",
SpeakersSettings.swift:172–178); "Refresh Description" likewise (332–338, TODO in code).
HIG: hide unavailable commands; a help tooltip pointing at the CLI can carry the hint.

### S6 · noticeable · Developer telemetry in the detail form
"Embedding: N dims" and raw source paths as first-class rows (299–311). Users care about
name, voiceprint count, and when enrolled; dims/paths are debug data.
**Fix direction:** drop or fold into a tooltip / "Show details" disclosure.

### S9 · nitpick · Double-chromed text fields
`.textFieldStyle(.roundedBorder)` inside grouped Forms (SpeakersSettings.swift:278; API
keys SecureField SettingsView.swift:197) — grouped forms supply their own field chrome.

### S13 · nitpick · Rename commits only via button
No `.onSubmit` on the name field (274–285); Enter should commit like the button.

## Copy & tone

### S7 · nitpick · Two help-text idioms in one form
Dictation uses a section *footer* for activation help but captions *inside* the toggle
label for Polish/HUD (DictationSettingsView.swift:37–42 vs 100–107). Pick footers.

### S8 · nitpick · Raw numeric key-code entry for custom trigger
TextField + "Numeric key code (e.g. 49 for Space)" (54–62). Works, reads dev-tool; the
polished form is a key-capture recorder well.

### S10 · nitpick · CLI jargon leaks into UI copy
"Averages embeddings via nota speakers merge" (358), "Run nota --identify to enrol
voices" (202), delete alert printing the store path (402). Decide one tone: UI-first
wording, CLI specifics in help tooltips.
