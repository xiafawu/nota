# Home redesign — design inspiration research

Asset for Linear ticket XIA-390 (wayfinder map XIA-389, "Nota home screen redesign").
Researched 2026-08-02 via three web sweeps: meeting-capture apps, whisper/dictation
apps, Apple-native + Liquid Glass guidance. Sources cited inline below.

## Takeaways for Nota (honor these in XIA-392 / XIA-393 prototypes)

1. **Home = recents + a few big verbs, never a settings dashboard.** Every
   well-reviewed app leads with content (recents/calendar) plus one or a few
   prominent actions. VoiceInk — the closest analog to today's Nota home — is
   the cited anti-pattern: a sidebar of settings tabs as the home screen, with
   reviewers wishing "your transcriptions were available directly from the
   dashboard." MacWhisper's launcher of **action cards** (Record, Open Files,
   Record App Audio) maps directly onto Nota's three entry cards.
2. **Primary actions are solid and colored; chrome is glass.** Voice Memos:
   one saturated red record button in otherwise monochrome chrome — and the
   primary action is *never* glass. Liquid Glass belongs only to the floating
   functional layer (toolbar, sidebar, floating pills); content cards, recents
   lists, and transcript views stay opaque/`.regularMaterial`.
3. **Drop-anywhere, zero-dialog file ingestion.** MacWhisper: drag a file onto
   the window and transcription starts immediately, no confirmation. The
   "transcribe a file" card should be a drop target, and the whole window
   should accept drops.
4. **Status is ambient and point-of-failure, not a hero panel.** Krisp warns
   about mic/system-audio permission *at call start*; Granola asks once at
   onboarding; superwhisper keeps a "get started" checklist on home that
   doubles as health surfacing. Progress lives inside the artifact (MacWhisper
   streams results into the transcript with a completion %) — validates the
   charting decision to demote preflight/cost to a quiet indicator.
5. **Recents earn polish through structure, not chrome.** Day-grouped
   (Today/Yesterday/date) with hover actions and top search (Wispr Flow);
   pinned/starred above chronology (Notes); rows expand inline instead of
   navigating away (Voice Memos); cards carry per-item identity — accent,
   status dots, snippet (Craft/Notes gallery). Nota already bands by recency;
   keep and extend rather than replace.
6. **Cheap aliveness: stats.** superwhisper/Wispr Flow put words-this-week /
   time-saved / WPM on home. Nota's history + usage records can produce
   minutes transcribed / meetings this week for near-zero cost — friendlier
   than a cost card.
7. **Never-empty first run.** Granola seeds a demo note during onboarding so
   the home list is never blank. Worth considering for Nota's first-run empty
   state.

## Liquid Glass do / don't (Tahoe-era, for implementation)

**Do:** glass only on toolbar/sidebar/floating pills; regular variant by
default; one glass sheet per view, adjacent glass grouped in one
`GlassEffectContainer`; concentric `.continuous` corners; 8pt grid; SF type
scale (`.largeTitle` page title, `.headline` sections, 17pt body, `.caption`
meta); `.primary/.secondary/.tertiary` opacity ladder; let content scroll
under the toolbar so refraction shows; keep primary action solid + colored.

**Don't:** glass on content cards/lists; max transparency over busy content
(Tahoe Music/Photos failure); different transparency for same chrome in
sibling views; clear variant without a dimming layer; glass on glass; text
<11pt; targets <44pt.

(Existing repo trap still applies: `glassEffect` in a transparent NSPanel is
flat blur — floating HUD surfaces need AppKit `NSGlassEffectView`.)

---

## Sweep 1 — Meeting-capture apps

### Granola

- **Home is the calendar.** Upcoming meetings on launch; sidebar with My notes
  (private) + team space + folders; notes list under an Upcoming section.
  Onboarding seeds a demo note so the list is never empty.
  (https://meetingnotes.com/blog/granola-ai-teardown,
  https://docs.granola.ai/help-center/getting-started/granola-101)
- **Primary action is clicking the meeting, not a Record button**; ad-hoc =
  secondary "New Note". Pre-call notifications (5 min / 1 min) carry the start
  flow; meeting detected → "record?" prompt.
- **Provenance as UI:** user text black, AI text gray with timestamp links;
  clicking a summary line reveals transcript + audio segment behind it.
  (https://wondertools.substack.com/p/granolaguide)
- **Ambient status:** "dancing bars" while transcribing, no modal. Notepad
  deliberately looks like Apple Notes — zero learning curve as stated intent.
- Figma community recreation of the macOS UI exists for pixel study:
  https://www.figma.com/community/file/1621324496539635584/

### Otter / Fathom / Krisp (secondary)

- Otter: homepage lists all meetings; "+" top-right hosts/imports; web-first
  feel is its chief criticism.
- Fathom: top-center **drawer**, one explicit "Capture Now" verb; panel hides
  itself from screen sharing. (https://help.fathom.video/en/articles/449088)
- Krisp: floating widget with live mic meter + feature status; **permission
  warnings fire at call start**, not buried in settings.

## Sweep 2 — Whisper/dictation apps

### superwhisper

- Home = stats row (WPM, words this week, time saved) + **"Get started"
  checklist** (doubles as permanent health surface) + recording controls +
  recent sessions. Sidebar: Home, Modes, Vocabulary, Config, Sound, Models,
  History. (https://max-productive.ai/ai-tools/superwhisper/)
- Models screen shows cloud vs offline side by side with speed/accuracy bars;
  download state is a property of the row, not a dialog.

### VoiceInk — the anti-pattern

- Settings-heavy sidebar as main window; "functional but basic"; reviewers:
  dashboard "a little bit confusing", want transcriptions on the dashboard.
  Daily use pushed to menu bar + mini recorder.
  (https://www.getvoibe.com/resources/voiceink-review/)

### MacWhisper

- Home = launcher of **action cards**: Open Files, New Recording, Record App
  Audio, Models, Dictation, Batch — plus history section on the same screen.
  Drag-drop starts transcription with **no confirmation dialog**. Progress
  streams into the transcript view with completion %. Document model (v14
  transcript editor: edit in place, reassign speakers).
  (https://fltmag.com/automated-transcription-with-macwhisper/,
  https://9to5mac.com/2026/07/14/macwhisper-14-launches...)

### Wispr Flow

- Hub window: welcome header with totals, stats carousel (streak, WPM,
  percentile), search, then history grouped Today/Yesterday/date with hover
  actions. Dictation itself is hotkey-only; optional draggable, edge-docking
  **Flow Bar** pill (hidden by default). Widely cited best-in-category UI:
  soft, low density, generous whitespace.
  (https://docs.wisprflow.ai/articles/5096240724-...,
  https://zackproser.com/blog/wisprflow-review)

## Sweep 3 — Apple-native + Liquid Glass

### Voice Memos (macOS 26)

- Two/three-pane split: folder sidebar, recordings list, detail. Launches into
  All Recordings — the app *is* the list plus one red record button pinned
  bottom-left. Button transforms in place while recording (waveform, pause,
  Done); recording auto-named, rename later; rows expand inline into a player.
  (https://support.apple.com/guide/voice-memos/welcome/mac)

### Notes (macOS 26)

- Three-column; New Note = one toolbar click, first line becomes title, saves
  automatically. Pinned section above chronology; **gallery view** = recents
  as thumbnail cards. Cited as a good Tahoe adoption: glass on format toolbar
  and pane dividers only, content stays opaque.
  (https://openmarkapp.com/blog/macos-tahoe-apps-liquid-glass)

### Craft

- Home shows documents as visual cards with cover/accent/status metadata;
  Daily Notes anchors "today" as an entry point (calendar-dated create
  button). The bar for third-party native polish: platform conventions +
  sub-second loads. (https://upbase.io/blog/craft-app-review/)

### Liquid Glass guidance

- Two layers: content (opaque) vs functional (glass). HIG: "Don't use Liquid
  Glass in the content layer."
  (https://developer.apple.com/videos/play/wwdc2025/219/,
  https://www.createwithswift.com/liquid-glass-redefining-design-...,
  https://github.com/giorgio-a11y/liquid-glass-guide)
- Reviewer-consensus failures: excess transparency over busy content (Music,
  Photos), inconsistent transparency across sibling views (Finder), glass on
  content, glass on glass.
  (https://www.macstories.net/stories/macos-26-tahoe-the-macstories-review/2/,
  https://sixcolors.com/post/2025/09/macos-26-tahoe-review-power-under-glass/)
- Accessibility free with system materials: Reduce Transparency, Increase
  Contrast, Reduce Motion all handled.
