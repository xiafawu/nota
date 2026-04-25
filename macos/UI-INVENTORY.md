# macOS UI Inventory (preserve mode baseline)

Snapshot of `macos/Nota/NotaApp.swift` (1125 lines, single file) as the starting point for the AI-UIconfig-skill apply. Everything here is **observed**, not aspirational — used to guide tokenization and composer/UI split without any visual change.

## Top-level types (7)

| Line | Type | Role | Disposition |
|---|---|---|---|
| 9 | `NotaApp: App` | Entry point, scene + commands | Composer (App/) |
| 50 | `SettingsView: View` | Single toggle (Remember speakers) | Pure UI (UI/) |
| 71 | `AppDelegate: NSObject` | NSApplication URL handler | Composer (App/) |
| 81 | `NotaModel: ObservableObject` | All runtime: file IO, transcribe pipeline, history, clipboard, export | Composer (App/) |
| 421 | `HistoryEntry` | Plain data model | Pure UI (UI/, used by render-state) |
| 778 | `RichTextViewer: NSViewRepresentable` | NSScrollView + NSTextView wrapper | Pure UI (UI/) |
| 873 | `ContentView: View` | NavigationSplitView root, toolbar, history pane, main pane, drop overlay | Pure UI (UI/) — to be sliced further |

## Private modifiers and extensions

| Line | Symbol | Role |
|---|---|---|
| 813 | `LiquidGlassModifier<S: Shape>` | Glass effect with reduce-transparency fallback |
| 827 | `LiquidGlassButtonModifier` | `.glass`/`.bordered` toggle |
| 853 | `DropTargetGlassModifier` | Drop overlay glass + accent stroke |
| 839 | `View` extension | `liquidGlass`, `liquidGlassButton`, `dropTargetGlass` |

These belong in `UI/Glass/` once split.

## Private helpers

Pipeline / runtime helpers (move to App/):
- `runHeadlessSmokeTestIfRequested`, `runHeadlessSmokeTest`, `writeStandardError`
- `sanitizedBaseName`, `notaTimestamp`, `notaOutputDirectory`, `shellQuoted`, `failureMarkdown`

Markdown rendering (move to UI/Markdown/):
- `renderMarkdownAsRichText`, `appendPlainLine`, `appendBulletLine`, `appendTranscriptLine`, `appendInlineMarkdownLine`, `appendInlineMarkdown`, `rtfData`

## UI surfaces and states

### Surface: `ContentView` root (NavigationSplitView)

| State | Trigger | Visual |
|---|---|---|
| Default | Always | Sidebar + detail with `.thinMaterial` + `.ultraThinMaterial` window background, hidden toolbar background |

### Surface: Toolbar (`.toolbar` block, lines 885–947)

| State | Trigger | Visual |
|---|---|---|
| Status hidden | `!isRunning && status == "Drop audio to transcribe"` | No status pill |
| Status visible (idle text) | status set after action (e.g. "Copied Markdown") | Pill with text |
| Status visible (running) | `isRunning` | ProgressView (small) + status text in pill |
| Share menu disabled | `markdown.isEmpty && lastOutputURL == nil` | Greyed |
| Share menu enabled | content present | Active button |

### Surface: HistoryPane (`historyPane`, lines 953–1035)

| State | Trigger | Visual |
|---|---|---|
| New transcription button (always) | n/a | Glass button h12/v10, accent tint 15% |
| New transcription disabled | `isRunning` | Greyed button |
| Empty | `history.isEmpty` | `tray` icon (26pt) + "No transcripts yet" + tertiary helper text |
| Populated | `!history.isEmpty` | Sidebar list with rows + `History` section header |
| Row selected | `selectedHistoryID == entry.id` | Default sidebar selection style |
| Row context menu | right-click | Open / Reveal / Delete |

### Surface: MainPane (`mainPane`, lines 1051–1091)

| State | Trigger | Visual |
|---|---|---|
| Empty (idle) | `!hasContent && !isRunning` | `tray.and.arrow.down` icon (72pt) + display name + display path |
| Empty (running) | `!hasContent && isRunning` | `waveform` icon with `.symbolEffect(.pulse)` |
| Has content | `hasContent` | `RichTextViewer` |
| Drop targeted overlay | `isDropTargeted` | Accent stroke border across whole pane (lineWidth 3, cornerRadius 0) |

### Surface: SettingsView (lines 50–69)

| State | Trigger | Visual |
|---|---|---|
| Toggle on | default + persisted | Standard form toggle, two-line label |
| Toggle off | user toggled | Same shape |

## Style cluster scan (38 sites)

Targets for `Tokens.swift` / `Metrics.swift` extraction. Each row is one or more occurrences in the source.

### Color / tint

| Source value | Use site | Token name |
|---|---|---|
| `.secondary.opacity(0.1)` | toolbar status pill glass tint | `Tokens.toolbarStatusTint` |
| `.accentColor.opacity(0.15)` | new-transcription button glass tint | `Tokens.primaryActionTint` |
| `Color.accentColor` | drop overlay stroke, drop target glass tint, idle icon when targeted | `Tokens.dropAccent` (= `.accentColor`) |
| `Color.secondary.opacity(0.2)` | drop fallback stroke (reduce transparency) | `Tokens.dropFallbackStroke` |
| `Color.primary.opacity(0.85)` | empty-state icon | `Tokens.emptyIconColor` |

### Font

| Source value | Use site | Token name |
|---|---|---|
| `.callout` | toolbar status text, history row title | `Tokens.statusFont`, `Tokens.historyTitleFont` |
| `.caption` | empty history label, history section header | `Tokens.captionFont` |
| `.caption2` | history row date | `Tokens.historyDateFont` |
| `.title` | empty-state name | `Tokens.emptyTitleFont` |
| `.system(size: 26, weight: .regular)` | empty history icon | `Tokens.emptyHistoryIconFont` |
| `.system(size: 72, weight: .semibold)` | main empty icon | `Tokens.emptyMainIconFont` |
| `monospacedSystemFont(ofSize: 12)` | code blocks | `Tokens.codeBlockFont` |
| `boldSystemFont(ofSize: 18)` | h2 markdown | `Tokens.h2Font` |
| `boldSystemFont(ofSize: 26)` | h1 markdown | `Tokens.h1Font` |
| `systemFont(ofSize: 14)` | bullets, body, transcript text | `Tokens.bodyFont` |
| `monospacedDigitSystemFont(ofSize: 12)` | transcript timestamp | `Tokens.timestampFont` |
| `boldSystemFont(ofSize: 14)` | transcript speaker | `Tokens.speakerFont` |
| `systemFont(ofSize: 13)` | hr separator | `Tokens.separatorFont` |

### Padding / frame / spacing

| Source value | Use site | Token name |
|---|---|---|
| `(.horizontal, 10) + (.vertical, 4)` | toolbar status pill | `Metrics.statusPillPadding` |
| `(.horizontal, 12) + (.vertical, 10)` | history new button content | `Metrics.newButtonContentPadding` |
| `(.horizontal, 10) + .top 10 + .bottom 6` | history new button outer | `Metrics.newButtonOuterPadding` |
| `(.horizontal, 16)` | history empty body | `Metrics.historyEmptyHorizontalPadding` |
| `.padding(.vertical, 2)` | history row | `Metrics.historyRowVerticalPadding` |
| `(.horizontal, 24)` | empty subtext | `Metrics.emptySubtextHorizontalPadding` |
| `padding(40)` | empty main outer | `Metrics.emptyMainOuterPadding` |
| `frame(minWidth: 780, minHeight: 560)` | window minimum | `Metrics.windowMinSize` |
| `frame(width: 420, height: 160)` | settings size | `Metrics.settingsSize` |
| `navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)` | sidebar width | `Metrics.sidebarWidth` |
| `navigationSplitViewColumnWidth(min: 520, ideal: 720)` | detail width | `Metrics.detailWidth` |
| `NSSize(width: 20, height: 18)` | RichTextViewer textContainerInset | `Metrics.richTextInset` |
| `VStack(spacing: 24)` | empty main | `Metrics.emptyMainSpacing` |
| `VStack(spacing: 10)` | empty main inner | `Metrics.emptyTextSpacing` |
| `VStack(spacing: 8)` | empty history | `Metrics.emptyHistoryStackSpacing` |
| `HStack(spacing: 8)` | new button | `Metrics.newButtonStackSpacing` |
| `HStack(spacing: 6)` | toolbar status | `Metrics.statusHStackSpacing` |
| `VStack(alignment: .leading, spacing: 2)` | settings label, history row | `Metrics.tightStackSpacing` |

### Shape / corner radius / line width

| Source value | Use site | Token name |
|---|---|---|
| `RoundedRectangle(cornerRadius: 20)` | drop overlay glass | `Metrics.dropCornerRadius` |
| `RoundedRectangle(cornerRadius: 10)` | new transcription button | `Metrics.primaryActionCornerRadius` |
| `RoundedRectangle(cornerRadius: 0)` | drop targeted border (full-bleed) | `Metrics.dropFullBleedCornerRadius` |
| `lineWidth: isTargeted ? 2 : 1` | drop fallback stroke | `Metrics.dropStrokeIdle` / `Metrics.dropStrokeActive` |
| `lineWidth: 3` | drop targeted overlay | `Metrics.dropTargetStrokeWidth` |

### Markdown paragraph metrics (renderMarkdownAsRichText)

| Source value | Use site | Token name |
|---|---|---|
| `paragraphSpacing: 4` | plain, inline, bullet, default | `Metrics.paraSpacingTight` |
| `paragraphSpacing: 5` | transcript line | `Metrics.paraSpacingTranscript` |
| `paragraphSpacing: 8` | h2 | `Metrics.paraSpacingH2` |
| `paragraphSpacing: 10` | h1 | `Metrics.paraSpacingH1` |
| `lineSpacing: 2` | all paragraph styles | `Metrics.lineSpacingDefault` |
| `headIndent: 18` | bullet | `Metrics.bulletHeadIndent` |

### Animation

| Source value | Use site | Token name |
|---|---|---|
| `.easeInOut(duration: 0.2)` | isRunning, hasContent | `Tokens.animFast` |
| `.easeInOut(duration: 0.15)` | isDropTargeted | `Tokens.animSnap` |

## Render-state shape (preview-driven)

Concrete states each pure-UI surface needs as input. Derived from observed branches above; nothing speculative.

```
HistoryPaneState
  isRunning: Bool
  rows: [HistoryRowState]            // empty == empty branch
  selectedID: HistoryEntry.ID?

HistoryRowState
  id: HistoryEntry.ID
  title: String
  relativeDate: String

MainPaneState
  kind: .empty(EmptyState) | .content(richText: NSAttributedString)
  isDropTargeted: Bool

EmptyState
  isRunning: Bool                    // drives waveform vs tray icon
  displayName: String
  displayPath: String
  isDropTargeted: Bool                // drives accent vs primary

ToolbarState
  statusPill: ToolbarStatusPillState? // nil hides pill
  isShareEnabled: Bool

ToolbarStatusPillState
  isRunning: Bool
  text: String
```

These are pure value types. `NotaModel` becomes the composer that maps its `@Published` properties to these states.

## Style clusters worth tokenizing first

Ordered by visibility and recent iteration cost:

1. **Toolbar pill metrics + tint** — most-iterated surface (5 toolbar-iter screenshots in `.claude/reviews/`).
2. **Drop overlay corner radius and stroke widths** — visible whenever user drags audio in.
3. **History new-transcription button** — already tinted with accent at 15%, the kind of value designers tweak first.
4. **Empty-state icon sizing (26pt + 72pt) and outer padding (40)** — main canvas.
5. **Markdown rendering font ladder (12/13/14/18/26)** — high reuse, easy to centralize.

## Out of scope

- `macos/NotaShare/ShareViewController.swift` — share extension, AppKit, 134 lines, separate target. Not refactored.
- TS pipeline (`src/**`) — untouched.
- Visual redesign — preserve mode forbids it.
