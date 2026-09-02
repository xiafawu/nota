import SwiftUI

// MARK: - The header band is gone
//
// `DocumentHeaderView` used to live here: one pinned line above the scrollable
// rich-text body, holding the title and nothing else (XIA-441, reduced to the
// title alone on 2026-08-19, **deleted 2026-09-02**).
//
// It existed to hold the metadata that ADR 0006 moved into the Details panel —
// the "date · duration" subtitle, the speaker chips, the fact strip and the
// tags. Those five parts folded away on scroll, so the band changed height, so
// it changed the scroll range that had decided it should fold: a state change
// driven by a value it alters, which the owner saw as the transcript *shaking*.
// Moving them out removed the loop; what was left was a whole non-scrolling
// region reserved for one line, and the owner crossed it out (2026-09-02).
//
// The title is now the document's own first line, drawn inside the reading
// column by `renderDocumentTitle` and composed onto the body by
// `MainPaneView.documentBody`. A line of text has no height that scroll can
// alter, so the loop is not merely damped or removed — there is no longer a
// band for it to happen in.
//
// The rest of this file is what the Details panel draws: the badge rule, the
// speaker chips, the tag row, and the focus-loss rule the two inline editors
// share.

// MARK: - What the Details button announces

/// **When the Details button announces something, and when it stays quiet.**
///
/// Putting the document's metadata behind a button costs one thing, and only
/// one: some of what is back there *asks* rather than tells, and a question
/// nobody sees is a question that is never answered.
///
/// Two things ask, and they are the only two.
///
/// A speaker chip holding a suggestion is Nota asking — "Speaker 2 → Kenny
/// Kim? 0.62", accept or dismiss — and it asks exactly once, when a
/// transcription lands. Behind a panel nobody opens, that question is never
/// seen and the speaker stays unnamed forever.
///
/// A `summaryOutdated` record is Nota asking too: a rename landed on a summary
/// that still names the old speaker, and one click regenerates it. That
/// question used to have a dot of its own on the Summary button; merging the
/// two buttons must not merge away the question.
///
/// Nothing else earns one. The subtitle, the fact strip and the tags state,
/// they do not ask, and an unnamed speaker with no suggestion is not waiting on
/// an answer either. A badge lit for every document would be lit permanently
/// and would say nothing.
///
/// **One dot, and the label says which.** A merged button that lights for two
/// claimants and names only the first hides the second for good, so `label`
/// names both when both are waiting, and `.help` and `.accessibilityLabel` read
/// the same string — the two can never disagree about what is waiting.
///
/// Pure, so the rule is asserted without laying anything out.
enum DocumentInfoBadge {
  static func hasPendingDecision(chips: [SpeakerChip]) -> Bool {
    chips.contains { $0.suggestion != nil }
  }

  /// What, if anything, is waiting on the owner behind the Details button.
  enum Waiting: Equatable {
    case speaker
    case summary
    case both
  }

  static func waiting(chips: [SpeakerChip], isSummaryOutdated: Bool) -> Waiting? {
    switch (hasPendingDecision(chips: chips), isSummaryOutdated) {
    case (true, true): return .both
    case (true, false): return .speaker
    case (false, true): return .summary
    case (false, false): return nil
    }
  }

  /// The one string the button's `.help` AND `.accessibilityLabel` both read.
  ///
  /// `isGeneratingSummary` is the ring's state, and it is here rather than left
  /// to the `ProgressView` inside the button because the button's own
  /// `accessibilityLabel` replaces its children: a run in flight was drawn and
  /// never said, so the only feedback for a press that spends a model call was
  /// a spinning glyph.
  static func label(_ waiting: Waiting?, isGeneratingSummary: Bool = false) -> String {
    let base: String
    switch waiting {
    case nil:
      base = "Details"
    case .speaker:
      base = "Details — a speaker suggestion is waiting"
    case .summary:
      base = "Details — the summary is out of date"
    case .both:
      base = "Details — a speaker suggestion is waiting and the summary is out of date"
    }
    return isGeneratingSummary ? base + " — generating the summary" : base
  }
}

// MARK: - Speaker chips

/// One chip per speaker: an identity-colored dot plus the final display name.
/// The diarization mapping ("Speaker 1 → Kenny Kim") is implementation detail —
/// it lives in the tooltip and the rename popover, never on the chip face.
///
/// Internal rather than file-private: the Details panel (`SummaryRailView`) is
/// what draws it now. Its parts below stay private — only the strip crosses the
/// file boundary.
struct SpeakerChipStrip: View {
  @Binding var chips: [SpeakerChip]
  let onRename: (_ label: String, _ newName: String) -> Void
  var onAcceptSuggestion: (_ label: String) -> Void = { _ in }
  var onDismissSuggestion: (_ label: String) -> Void = { _ in }

  var body: some View {
    FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
      ForEach(Array(chips.enumerated()), id: \.element.id) { index, _ in
        SpeakerChipButton(
          chip: $chips[index],
          color: SpeakerColors.color(at: index),
          onRename: onRename,
          onAcceptSuggestion: onAcceptSuggestion,
          onDismissSuggestion: onDismissSuggestion
        )
      }
    }
  }
}

private struct SpeakerChipButton: View {
  @Binding var chip: SpeakerChip
  let color: Color
  let onRename: (_ label: String, _ newName: String) -> Void
  var onAcceptSuggestion: (_ label: String) -> Void = { _ in }
  var onDismissSuggestion: (_ label: String) -> Void = { _ in }

  @State private var showRenamePopover = false
  @State private var draft = ""
  /// Set by the Return path so the popover's own dismissal does not commit the
  /// same draft a second time (P-C6).
  @State private var isCommitting = false

  private var displayName: String {
    chip.name.isEmpty ? chip.label : chip.name
  }

  var body: some View {
    Group {
      if let suggestion = chip.suggestion {
        suggestionChip(suggestion)
      } else {
        renameChip
      }
    }
    .animation(Tokens.animSnap, value: chip.suggestion)
  }

  /// A pending suggestion takes over the chip face: `<label> → <name>?
  /// <score>` with accept/dismiss. Not a Button — the actions are the two
  /// buttons inside, so the whole face must not swallow their clicks.
  private func suggestionChip(_ suggestion: SpeakerSuggestion) -> some View {
    HStack(spacing: 4) {
      Circle()
        .fill(color)
        .frame(width: Metrics.speakerDotSize, height: Metrics.speakerDotSize)
      Text("\(chip.label) → \(suggestion.suggestedName)? \(suggestion.scoreText)")
        .font(Tokens.historyTagFont)
        .foregroundStyle(.ground(.speaker))
        .lineLimit(1)
      Button {
        onAcceptSuggestion(chip.label)
      } label: {
        Image(systemName: "checkmark")
          // 9pt, not 8: the two glyphs sit 4pt apart and one of them enrolls a
          // voiceprint, so the pair has to be separable (P-C3).
          .font(.system(size: 9, weight: .bold))
          .frame(width: Metrics.chipHitTarget, height: Metrics.chipHitTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.green)
      .help("Accept \"\(suggestion.suggestedName)\" and enroll this voiceprint")
      .accessibilityLabel("Accept suggestion")
      Button {
        onDismissSuggestion(chip.label)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .frame(width: Metrics.chipHitTarget, height: Metrics.chipHitTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.ground(.speaker))
      .help("Dismiss this suggestion")
      .accessibilityLabel("Dismiss suggestion")
    }
    .padding(.horizontal, Metrics.tagPillH)
    .padding(.vertical, Metrics.tagPillV)
    .background(
      Capsule()
        .strokeBorder(
          style: StrokeStyle(lineWidth: 1, dash: [2, 2])
        )
        .foregroundStyle(color.opacity(0.7))
    )
    .help(suggestionHelp(suggestion))
  }

  /// The usual rename face. Chips with no name yet render a subtle
  /// unnamed state — dashed outline + tertiary text — so "still needs a
  /// name" reads at a glance without shouting (decision 5).
  private var renameChip: some View {
    Button {
      draft = chip.name
      showRenamePopover = true
    } label: {
      HStack(spacing: 4) {
        Circle()
          .fill(color)
          .frame(width: Metrics.speakerDotSize, height: Metrics.speakerDotSize)
        Text(displayName)
          .font(Tokens.historyTagFont)
          .foregroundStyle(chip.name.isEmpty ? .ground(.timestamp) : .ground(.speaker))
          .lineLimit(1)
        statusAccessory
      }
      .padding(.horizontal, Metrics.tagPillH)
      .padding(.vertical, Metrics.tagPillV)
    }
    .buttonStyle(.plain)
    .background(unnamed ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Tokens.tagPillFill), in: Capsule())
    .overlay {
      if unnamed {
        Capsule()
          .strokeBorder(
            style: StrokeStyle(lineWidth: 1, dash: [3, 2])
          )
          .foregroundStyle(.ground(.timestamp))
      }
    }
    .help(helpText)
    .popover(isPresented: $showRenamePopover, arrowEdge: .bottom) {
      renamePopover
    }
    // Dismissing the popover by clicking away COMMITS a typed name, through
    // the same call Return makes (P-C6) — the same rule the tag field keeps,
    // written down once in `InlineEditFocusLoss`.
    //
    // Naming a chip enrols a voiceprint, so the guard is not decoration:
    // `draft` is seeded with `chip.name` on open, and an unchanged draft is a
    // dismissal that must enrol nothing. `isCommitting` keeps the Return path
    // from arriving here a second time.
    .onChange(of: showRenamePopover) { _, shown in
      guard !shown else { return }
      guard !isCommitting else {
        isCommitting = false
        return
      }
      guard
        InlineEditFocusLoss.outcome(draft: draft, committed: chip.name) == .commit
      else { return }
      onRename(chip.label, draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  /// True when the chip has no display name and no suggestion pending — and
  /// the label is a diarizer placeholder. A label that is already a person's
  /// name (auto-identified at run time, so no sidecar entry exists) is named,
  /// whatever the sidecar says.
  private var unnamed: Bool {
    chip.name.isEmpty && chip.suggestion == nil && chip.hasGenericLabel
  }

  private func suggestionHelp(_ suggestion: SpeakerSuggestion) -> String {
    "\(chip.label) → \(suggestion.suggestedName)? \(suggestion.scoreText) — accept or dismiss"
  }

  /// Enroll status rides as a small accessory; the dot is reserved for the
  /// speaker's identity color.
  @ViewBuilder
  private var statusAccessory: some View {
    switch chip.indicator {
    case .enrolling:
      ProgressView().controlSize(.mini).scaleEffect(0.7)
    case .skipped:
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 8))
        .foregroundStyle(.yellow)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: 8))
        .foregroundStyle(CraftTokens.failure)
    case .none, .pending, .enrolled:
      EmptyView()
    }
  }

  private var helpText: String {
    var parts: [String] = []
    if chip.name.isEmpty {
      parts.append("\(chip.label) — click to name this speaker")
    } else if chip.name != chip.label {
      parts.append("\(chip.label) → \(chip.name)")
    } else {
      parts.append(chip.name)
    }
    if let tooltip = chip.indicator.tooltip {
      parts.append(tooltip)
    }
    return parts.joined(separator: " · ")
  }

  private var renamePopover: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(chip.label)
        .font(.caption)
        .foregroundStyle(.ground(.speaker))
      TextField("Speaker name", text: $draft)
        .frame(width: Metrics.speakerPopoverFieldWidth)
        .onSubmit { commit() }
      if let tooltip = chip.indicator.tooltip {
        Text(tooltip)
          .font(.caption2)
          .foregroundStyle(.ground(.speaker))
          .frame(maxWidth: Metrics.speakerPopoverFieldWidth, alignment: .leading)
      }
    }
    .padding(12)
  }

  private func commit() {
    isCommitting = true
    showRenamePopover = false
    onRename(chip.label, draft.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// What losing focus does to an inline editor's draft — one answer for the tag
/// field and the speaker-name popover (P-C6).
///
/// Both used to throw a typed value away on focus loss, silently, one scroll
/// below a summary draft protected by a three-button alert and a persisted
/// policy. Focus loss now commits what the Return key would have committed, and
/// Escape keeps its own meaning. It discards only when there is nothing to
/// lose: a draft that is empty after trimming, or one still equal to the value
/// already on the record — which is what keeps a speaker popover the owner
/// merely opened and clicked away from enrolling a voiceprint.
enum InlineEditFocusLoss {
  enum Outcome: Equatable {
    /// The draft carries something new: commit it, through the same call
    /// Return makes, with the same validation.
    case commit
    /// Nothing typed, or nothing changed: closing loses nothing.
    case discard
  }

  /// `committed` is the value already on the record — the empty string for a
  /// field that opens blank, like the add-tag chip.
  static func outcome(draft: String, committed: String = "") -> Outcome {
    let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return .discard }
    guard value != committed.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return .discard
    }
    return .commit
  }
}

// MARK: - Editable tags (record-driven)

/// Inputs for the editable tag row: current record tags plus add/remove and
/// generate callbacks that persist through the CLI's apply-enrichment and tag
/// verbs. Generation progress and failure ride on the row (decision 28).
struct EnrichmentTagEditing {
  var tags: [String]
  /// True while the tag generation verb is in flight — the row shows a
  /// progress spinner instead of the generate affordance (decision 28).
  var isGenerating: Bool
  /// The tag generation failure message. The controller's error channel is
  /// shared with the summary rail; only tagging-kind failures belong here.
  var errorMessage: String?
  /// Regeneration over edited tags requires confirmation (edited-is-protected;
  /// the row presents the confirm alert).
  var needsConfirm: Bool
  var onAdd: (String) -> Void
  var onRemove: (String) -> Void
  /// Starts tag generation (unconfirmed — the row gates on `needsConfirm`).
  var onGenerate: () -> Void
}

/// Internal for the reason `SpeakerChipStrip` is: the Details panel draws it.
struct EditableTagRow: View {
  let state: EnrichmentTagEditing

  @State private var showGenerateConfirm = false

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
        ForEach(state.tags, id: \.self) { tag in
          RemovableTagChip(tag: tag, onRemove: { state.onRemove(tag) })
        }
        // Decision 28: the generate-tags affordance sits on the tag row —
        // "Generate tags" when empty, a `+` when not — because it is the
        // action of the thing displayed there (ADR 0005). Progress replaces
        // it while a generation runs.
        if state.isGenerating {
          ProgressView()
            .controlSize(.mini)
            .padding(.horizontal, Metrics.tagPillH)
            .padding(.vertical, Metrics.tagPillV)
            .help("Generating tags…")
        } else {
          generateButton
        }
        AddTagChip(onAdd: state.onAdd)
      }
      if let message = state.errorMessage {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(CraftTokens.failure)
          .lineLimit(2)
      }
    }
    .alert("Regenerate tags?", isPresented: $showGenerateConfirm) {
      Button("Cancel", role: .cancel) {}
      Button("Regenerate") { state.onGenerate() }
    } message: {
      Text("You've edited these tags. Generated tags are merged with yours — manual tags are kept.")
    }
  }

  private var generateButton: some View {
    Button {
      if state.needsConfirm {
        showGenerateConfirm = true
      } else {
        state.onGenerate()
      }
    } label: {
      if state.tags.isEmpty {
        Text("Generate tags")
          .font(Tokens.historyTagFont)
      } else {
        Image(systemName: "plus")
          .font(.system(size: 9, weight: .bold))
      }
    }
    .buttonStyle(.plain)
    .foregroundStyle(.ground(.speaker))
    .padding(.horizontal, Metrics.tagPillH)
    .padding(.vertical, Metrics.tagPillV)
    .background(
      Capsule()
        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        .foregroundStyle(.ground(.timestamp))
    )
    .help("Generate tags")
    .accessibilityLabel(state.tags.isEmpty ? "Generate tags" : "Generate more tags")
  }
}

/// A tag pill whose × affordance appears only on hover (E2: chips clean at rest).
///
/// The × is an **overlay**, never an element of the pill's layout (P-C4).
/// Inserting it on hover widened the pill by ~10pt the instant the pointer
/// landed on it, and because the chips sit in a `FlowLayout` a hover near a
/// line break pushed later chips onto the next line — the control moving under
/// the pointer that is aiming at it, which is exactly the rule the moment tally
/// keeps (`RecordingPane.markerCount`, an overlay for the same reason). The
/// pill is one width in both states and the glyph fades in over trailing
/// padding reserved for it, so it never sits on the last character.
///
/// `hovering` seeds the state so the invariant can be laid out both ways in a
/// test (`testATagPillIsTheSameWidthHoveredAndNot`); nothing in the app passes it.
struct RemovableTagChip: View {
  let tag: String
  let onRemove: () -> Void

  @State private var isHovering: Bool

  init(tag: String, onRemove: @escaping () -> Void, hovering: Bool = false) {
    self.tag = tag
    self.onRemove = onRemove
    _isHovering = State(initialValue: hovering)
  }

  var body: some View {
    Text(tag)
      .font(Tokens.historyTagFont)
      .foregroundStyle(.ground(.speaker))
      .padding(.leading, Metrics.tagPillH)
      .padding(.trailing, Metrics.tagPillH * 2)
      .padding(.vertical, Metrics.tagPillV)
      .background(Tokens.tagPillFill, in: Capsule())
      .overlay(alignment: .trailing) {
        Button(action: onRemove) {
          Image(systemName: "xmark")
            // The glyph stays 7pt; only the rectangle that takes the click
            // grows, the treatment the drawer, rail and usage-sheet closes
            // already use (P-C3).
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.ground(.speaker))
            .frame(width: Metrics.chipHitTarget, height: Metrics.chipHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remove tag")
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
      }
      .onHover { isHovering = $0 }
      .animation(Tokens.animSnap, value: isHovering)
  }
}

/// Always-visible dashed "+ add tag" chip; clicking reveals an inline field
/// (Enter commits, focus loss commits too, Esc cancels — see
/// `InlineEditFocusLoss`).
private struct AddTagChip: View {
  let onAdd: (String) -> Void

  @State private var isEditing = false
  @State private var draft = ""
  @FocusState private var fieldFocused: Bool

  var body: some View {
    Group {
      if isEditing {
        TextField("tag", text: $draft)
          .font(Tokens.historyTagFont)
          .textFieldStyle(.plain)
          .frame(minWidth: 56, maxWidth: 110)
          .focused($fieldFocused)
          .onSubmit { commit() }
          .onExitCommand { cancel() }
          // Focus loss COMMITS (P-C6). Clicking anywhere else — including the
          // Details panel's own full-window backdrop — used to throw the typed
          // tag away with no prompt and no trace, one scroll below a summary
          // draft protected by a three-button alert. Escape still cancels, so
          // the two gestures stop meaning the same thing.
          .onChange(of: fieldFocused) { _, focused in
            guard !focused else { return }
            switch InlineEditFocusLoss.outcome(draft: draft) {
            case .commit: commit()
            case .discard: cancel()
            }
          }
          .padding(.horizontal, Metrics.tagPillH)
          .padding(.vertical, Metrics.tagPillV)
          .background(
            Capsule().strokeBorder(.ground(.timestamp), lineWidth: 1)
          )
          .onAppear { fieldFocused = true }
      } else {
        Button {
          draft = ""
          isEditing = true
        } label: {
          HStack(spacing: Metrics.tagToggleIconSpacing) {
            Image(systemName: "plus")
              .font(.system(size: 7, weight: .bold))
            Text("add tag")
              .font(Tokens.historyTagFont)
          }
          .foregroundStyle(.ground(.speaker))
          .padding(.horizontal, Metrics.tagPillH)
          .padding(.vertical, Metrics.tagPillV)
        }
        .buttonStyle(.plain)
        .background(
          Capsule()
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            .foregroundStyle(.ground(.timestamp))
        )
        .help("Add a tag")
      }
    }
    .animation(Tokens.animSnap, value: isEditing)
  }

  private func commit() {
    let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    isEditing = false
    fieldFocused = false
    draft = ""
    if !value.isEmpty {
      onAdd(value)
    }
  }

  private func cancel() {
    isEditing = false
    fieldFocused = false
    draft = ""
  }
}

#if DEBUG
#Preview("speaker chips") {
  SpeakerChipStrip(
    chips: .constant([
      SpeakerChip(label: "Speaker 1", name: "Freya Wu", indicator: .enrolled),
      SpeakerChip(label: "Speaker 2", name: "", indicator: .none),
    ]),
    onRename: { _, _ in }
  )
  .padding()
  .frame(width: 320)
}

#endif