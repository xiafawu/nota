import SwiftUI

// MARK: - The Details panel (XIA-415; merged with the info card 2026-08-19)

/// **The document's one panel.** A fixed-width (380pt, decision 1) SwiftUI
/// overlay anchored in the window's bottom-right corner, opened by the one
/// Details button in the local cluster beside Share.
///
/// It began as the summary rail and it still holds all of that — narrative,
/// topics, decisions, action items, the `summaryOutdated` banner, the in-flight
/// row (model name + Cancel), failures, and Edit / Regenerate / Close
/// (decision 5). What joined it is everything `DocumentInfoCard` used to draw
/// in an overlay of its own: the subtitle, the speaker chips, the record's fact
/// strip and the tags, above the summary and separated from it by a hairline.
///
/// **One panel, one scroll.** Not tabs, not a second card, and not a second
/// scroll view — the details block is the first thing inside the *existing*
/// `ScrollView`, so there is one set of horizontal paddings and one thing that
/// scrolls. Two surfaces for one document is what this merge deleted; growing
/// two arms inside one of them would be the same mistake with fewer windows.
///
/// The details block sits **above** the summary fork on purpose: drawing the
/// chips inside it would blank a document's speaker names for the duration of
/// a generation. The fork itself branches on `activity == .summarizing` and
/// not on `!= .idle`, for the matching reason on the other side — the tag row
/// that starts a tag run is now four rows above the summary it would otherwise
/// have replaced (`summaryIsInFlight`).
///
/// **It is the summary's only home** (ADR 0006 addendum, 2026-09-02). The
/// document body used to draw `## Summary` and its three lists as well, so a
/// summarized meeting rendered the same four fields twice; the body copy went.
/// What that costs is an **imported** `.md`, which has no history record and so
/// no record-fed summary at all — and a document may not lose something because
/// of where it was opened from. So the summary half falls back to parsing the
/// open markdown's own `## Summary` (`.parsedSummary`, below). It is read-only,
/// and it waits for the record lookup exactly as the notice does.
///
/// **Opening is free; generating is not.** The button no longer starts a
/// summary (the old dual-purpose click, decision 10). The only way to start one
/// is `generateBlock`'s button, in the slot where the narrative would be — so
/// the press that spends a model call is the press that says it does, and the
/// press that opens a panel to read a speaker's name spends nothing.
///
/// The panel owns its dismissal surface (full-window backdrop + hidden Escape
/// button, the same treatment the history drawer's host layer uses) so every
/// close runs the decision-13 draft policy from the one place that knows the
/// draft: not editing → close; Save it → commit + close; Ask me → confirm
/// (save / discard / keep editing). The policy itself lives on `NotaModel`
/// because record switches and phase leaves close the panel from the model
/// side (decisions 6/7) and must resolve the draft before the record is
/// replaced. **That policy now governs the whole panel, and may not be
/// weakened**: someone who opened it to read a speaker name must not be able to
/// lose an in-progress summary edit on the way out. Nothing added here calls
/// `model.closeSummaryRail()` or otherwise routes around `requestDismissal()`.
///
/// **One ink, top to bottom.** The four detail blocks were moved in wholesale
/// and only the two this file draws itself — the subtitle and the tags — were
/// converted, so in one `VStack` at one spacing the panel read ground ink,
/// label colours, label colours, ground ink. Every secondary run in here is
/// `GroundInk.Tier.speaker` now and every tertiary one is `.timestamp`, and the
/// two views it embeds (`SpeakerChipStrip`, `RecordFactStripView`) draw from the
/// same table. This is not the ground-contrast argument — the panel is a
/// `craftGlassPanel` — it is that a surface may not disagree with itself about
/// which system its own rows come from. Semantic *meaning* colours stay
/// semantic: `CraftTokens.failure`, the outdated banner's warning, and the
/// system tint on a link.
struct SummaryRailView: View {
  @ObservedObject var model: NotaModel
  @ObservedObject private var enrichment = EnrichmentController.shared
  /// Confirm-gated regeneration over an edited summary (decision 5).
  @State private var confirmTarget: EnrichmentField?
  /// Measured width of the decisions/action-items block, driving the
  /// two-columns-vs-stacked choice (see `structuredSummary`). Kept exactly as
  /// the slot had it — at 380pt the rail permanently takes the stacked arm
  /// (decision 4).
  @State private var structuredColumnsWidth: CGFloat = 0
  /// How tall the narrative reads when it is not being edited, so the editor
  /// can open at that height rather than jumping to a fixed minimum.
  @State private var narrativeHeight: CGFloat = 0

  // MARK: The details half's inputs
  //
  // All derived from the model the panel already holds rather than passed in,
  // so the one mount site in `ContentView` did not have to learn about them.
  //
  // `parseDocumentMeta` really does cost only a header block: it enumerates
  // lines and STOPS at the first `## ` without materializing the rest of the
  // document. That is load-bearing here rather than a nicety — this property
  // is read two to four times per body evaluation, and the panel's own
  // `TextEditor` writes an `@Published` on the model it observes, so a parse
  // that split the whole `.md` first would re-split a long meeting on every
  // keystroke of a summary edit.

  private var meta: DocMeta? {
    parseDocumentMeta(model.markdown)
  }

  /// The record's facts, drawn as a dot-separated strip under the chips
  /// (XIA-429). The **same** `RecordFacts` the receipt drew at Stop — one
  /// model, two renderings, so the moment and the document cannot drift. Nil
  /// for an imported `.md`, which is what omits the strip.
  private var facts: RecordFacts? {
    model.openRecordFacts
  }

  /// Tags become editable chips only when the document has a history record —
  /// the record is truth for tag content; imported markdown keeps static pills.
  /// The generate-tags affordance rides the row (decision 28), carrying its
  /// progress, its failure, and the edited-tags confirm gate.
  ///
  /// Its `errorMessage` keeps the `errorField == .tags` filter, and the summary
  /// half keeps the `== .summary` one: the controller has a single error
  /// channel and both halves of this panel now draw out of it, so an unfiltered
  /// read would print one failure twice, six inches apart — and the *unfiltered
  /// inverse* (`!= .tagging`) put a failed tag add under the summary, where its
  /// button reads "Try Again" and spends a model call.
  private var tagEditing: EnrichmentTagEditing? {
    guard let record = enrichment.record else { return nil }
    return EnrichmentTagEditing(
      tags: record.tags,
      isGenerating: enrichment.activity == .tagging,
      errorMessage: enrichment.errorField == .tags ? enrichment.errorMessage : nil,
      needsConfirm: enrichmentNeedsConfirm(record: record, target: .tags),
      onAdd: { enrichment.addTag($0) },
      onRemove: { enrichment.removeTag($0) },
      onGenerate: { enrichment.generateTags() }
    )
  }

  /// Whether the details half has anything to draw. Four parts, four sources —
  /// an imported `.md` with no chips and no tags has none of them.
  private var hasDetails: Bool {
    if let meta, !meta.subtitle(facts: facts).isEmpty { return true }
    if !model.speakerChips.isEmpty { return true }
    if let facts, !facts.isEmpty { return true }
    if tagEditing != nil { return true }
    return !(meta?.tags.isEmpty ?? true)
  }

  /// Said in place of the summary half when the open document has no history
  /// record **and none of its own** — the markdown carries no `## Summary`
  /// either, so there is genuinely nothing to draw. Named so a test can reach
  /// it: the rule is that nothing about a document silently disappears because
  /// of where it came from, and a panel that simply ended at the hairline would
  /// be exactly that.
  ///
  /// It states the **absence** and nothing else. It used to open "Imported
  /// file —", which is a claim about provenance that `record == nil` does not
  /// support: a failed transcription puts a failure document in the pane with
  /// no record behind it either, and that owner was told their meeting was a
  /// file they had opened.
  static let noRecordNotice =
    "No history record for this document, so there is no summary to generate."
  /// Minimum measured width at which decisions + action items render side by
  /// side; below it they stack. Each column keeps a readable wrapped measure
  /// (~28 characters of `.subheadline`) at this threshold. Do NOT lower this
  /// or swap in `ViewThatFits` — that was tried and rejected (decision 4).
  private static let twoColumnMinWidth: CGFloat = 480

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      // Full-window backdrop: click-outside dismisses through the draft
      // policy. The panel floats above it; the window content is inert while
      // the rail is up, exactly like the history drawer's layer.
      Color.black.opacity(0.0001)
        .contentShape(Rectangle())
        .onTapGesture { requestDismissal() }
        .ignoresSafeArea()
        // It is a dismissal target for the mouse and nothing at all for an
        // assistive cursor: an invisible full-window rectangle is not an
        // element, and announcing one would be the only thing VoiceOver found
        // between the transcript and the panel.
        .accessibilityHidden(true)

      panel
        .padding(.horizontal, CraftTokens.spacing16)
        // Two asymmetric margins, each paying for something specific.
        //
        // Top: the panel's shadow is drawn *inside* the content area, which is
        // clipped at the toolbar's edge. A card flush against that edge has
        // the upper half of its shadow cut off in a straight line — the shadow
        // reaches `shadowRadius - shadowOffsetY` above the card, so that much
        // margin is what keeps it whole.
        //
        // Bottom: the rail rises from the local cluster's own corner and must
        // not land on top of the buttons that opened it. Clearing the cluster
        // means its full diameter plus a gap, on top of the ordinary inset.
        .padding(.top, Self.shadowRadius - Self.shadowOffsetY)
        .padding(
          .bottom,
          CraftTokens.spacing16 + LocalCluster.diameter + CraftTokens.spacing8
        )
        .zIndex(1)

      // Escape dismisses via a hidden cancel action — but while editing it
      // COMMITS under the default setting (decision 13, taken knowingly:
      // "Escape commits while editing, inverting its usual meaning").
      Button("") { requestDismissal() }
        .keyboardShortcut(.cancelAction)
        .hidden()
    }
    .alert(
      "Replace your edited summary?",
      isPresented: Binding(
        get: { confirmTarget == .summary },
        set: { if !$0 { confirmTarget = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { confirmTarget = nil }
      Button("Regenerate") {
        enrichment.generateSummary(force: true)
        confirmTarget = nil
      }
    } message: {
      Text("You've edited this summary. Regenerating replaces your version. Tags are kept and merged.")
    }
    .alert(
      "Unsaved summary edits",
      isPresented: $showDismissConfirm
    ) {
      Button("Save") { model.resolveSummaryRailDismissal(.save) }
      Button("Discard", role: .destructive) { model.resolveSummaryRailDismissal(.discard) }
      Button("Keep Editing", role: .cancel) { model.resolveSummaryRailDismissal(.keepEditing) }
    } message: {
      Text("Close the summary with unsaved edits?")
    }
    .onChange(of: model.isSummaryRailDismissalPending) { _, pending in
      showDismissConfirm = pending
    }
    // The panel is visually modal — the backdrop makes the window inert to
    // clicks while it is up — so it has to be modal to VoiceOver too, or the
    // assistive cursor goes on walking the transcript and the now-unpressable
    // Details button behind a surface nothing can be reached through.
    .accessibilityAddTraits(.isModal)
  }

  // MARK: Dismissal (decision 13)

  /// Ask-me confirm presentation mirror (see the alert wiring above: the
  /// alert's binding must not double-resolve through the model flag).
  @State private var showDismissConfirm = false

  private func requestDismissal() {
    model.requestSummaryRailDismissal()
  }

  // MARK: Panel

  private var panel: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      content
    }
    .frame(width: SummaryDrawerLayout.railWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .craftGlassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .shadow(color: .black.opacity(0.25), radius: Self.shadowRadius, y: Self.shadowOffsetY)
  }

  /// Named because the top margin is derived from them: the shadow's reach
  /// above the card is what decides how far below the toolbar edge the card
  /// has to sit to avoid being clipped.
  private static let shadowRadius: CGFloat = 24
  private static let shadowOffsetY: CGFloat = 8

  /// **A summary run, not any run.** The fork below replaces the whole summary
  /// half with the in-flight row, and the tags row that starts a *tag* run is
  /// four rows above it inside this same panel — so `activity != .idle` meant
  /// one press on "Generate tags" made the narrative disappear and be replaced
  /// by a progress row with a Cancel in it, under a heading reading SUMMARY,
  /// while the tag row drew its own spinner. Worse with the editor open: the
  /// owner's draft was unmounted under them while the dismissal policy went on
  /// governing text they could no longer see.
  ///
  /// It is the same predicate the Details button's ring uses, which is what
  /// makes the button and the panel agree about what is running.
  static func summaryIsInFlight(_ activity: EnrichmentActivity) -> Bool {
    activity == .summarizing
  }

  private var isGenerating: Bool {
    Self.summaryIsInFlight(enrichment.activity)
  }

  /// What the panel may honestly draw below the hairline.
  ///
  /// Four states, and three of them exist because `record == nil` answers more
  /// than one question. It means a document with no history record — and also a
  /// document whose record has not been read yet, because `NotaModel.loadChips`
  /// clears the record synchronously and looks the real one up in a detached
  /// task, so every recorded transcript is momentarily indistinguishable from an
  /// imported one on open. This slot is where the panel makes a *statement*
  /// about the document. An absence during a race is nothing; a sentence during
  /// a race is a false claim.
  ///
  /// `.parsedSummary` joined them when the summary left the document body (ADR
  /// 0006's 2026-09-02 addendum). An imported `.md` has no record, so the
  /// record-fed half draws nothing for it, and with the body copy gone its
  /// summary would be visible nowhere at all. The markdown's own `## Summary` is
  /// the answer — and it is ordered strictly **below** `.waitingForRecord` for
  /// the reason that state exists: parsing is instant and the disk read is not,
  /// so a fallback that did not wait would flash the document's own summary on
  /// open and then swap it for the record's, on every recorded transcript.
  enum SummaryHalf: Equatable {
    case summary
    /// The document's own `## Summary`, for a document with nothing behind it.
    case parsedSummary
    case noRecordNotice
    case waitingForRecord

    /// **Whether this half may offer a control that writes to a record.**
    ///
    /// Edit, Regenerate, the Edited pill, the saving spinner, Generate Summary
    /// — every one of them acts on a history record, and a parsed summary
    /// has none — there is nothing to write to and nothing to regenerate from.
    /// So they are *absent* there, not disabled, which is the same call ADR 0006
    /// already made for Edit and Regenerate above an empty slot: a dead control
    /// naming an object that does not exist reads as a feature that failed.
    ///
    /// Asked by both arms that draw a summary rather than typed at each of them,
    /// so "may this half write" has one answer and a test can hold it.
    var offersRecordControls: Bool { self == .summary }
  }

  /// `hasParsedSummary` defaults to false so the three original states are
  /// spelled exactly as they were: a settled document with no record and no
  /// summary of its own is still the one-line notice.
  static func summaryHalf(
    hasRecord: Bool,
    isResolvingRecord: Bool,
    hasParsedSummary: Bool = false
  ) -> SummaryHalf {
    if hasRecord { return .summary }
    if isResolvingRecord { return .waitingForRecord }
    return hasParsedSummary ? .parsedSummary : .noRecordNotice
  }

  /// The document's own summary, and **only** when there is no record to
  /// prefer. Guarded rather than merged: a record that carries a narrative but
  /// no key topics goes on drawing none, because the record is truth for a
  /// document that has one and a half-and-half summary is a document describing
  /// itself out of two sources.
  ///
  /// It also requires the document to be one whose body is **not already
  /// drawing that summary**. `DocumentBody.plan` opens a `.transcript` render
  /// after `## Full Transcript` — dropping the summary sections, which is what
  /// this fallback exists to re-home — but only for a document that *has* that
  /// heading. A foreign `.md` has none, so it degrades to rendering whole and
  /// its `## Summary` is already on screen in the reading column; parsing it
  /// into the panel as well would put the same text in two places, which is the
  /// exact failure ADR 0006's 2026-09-02 addendum exists to remove. Such a
  /// document falls through to the ordinary "no record behind this" line.
  ///
  /// Static and pure-ish so the guard is a fact a test can check — the view
  /// cannot be hosted (`NotaModel.init` sweeps the real `~/.nota`).
  static func parsedFallback(hasRecord: Bool, markdown: String) -> ParsedDocumentSummary? {
    guard !hasRecord else { return nil }
    guard markdown.contains(DocumentBody.transcriptHeading) else { return nil }
    return DocumentSummaryCache.summary(for: markdown)
  }

  private var parsedSummary: ParsedDocumentSummary? {
    Self.parsedFallback(hasRecord: enrichment.record != nil, markdown: model.markdown)
  }

  private var summaryHalf: SummaryHalf {
    Self.summaryHalf(
      hasRecord: enrichment.record != nil,
      isResolvingRecord: enrichment.isResolvingRecord,
      hasParsedSummary: parsedSummary != nil
    )
  }

  private var hasNarrative: Bool {
    enrichment.record?.hasSummaryNarrative ?? false
  }

  private var isEditing: Bool {
    model.isSummaryEditing
  }

  private var record: EnrichmentRecord? {
    enrichment.record
  }

  // MARK: Header (the panel's title and Close)

  /// **Details, not Summary.** The panel's top third is a subtitle, speaker
  /// chips, a fact strip and tags, so a header reading "Summary" would name a
  /// third of what is under it. The summary's own chrome — the Edited pill, the
  /// saving spinner, Edit / Regenerate / Cancel / Save — went *down* into
  /// `summarySectionHeader`, beside the thing it acts on: a button labelled
  /// Regenerate 200pt above the text it regenerates, and immediately above a
  /// speaker chip it does nothing to, is a verb pointed at the wrong object.
  ///
  /// The card's own × folded into this one rather than moving: there was
  /// already a Close here, and it is the one wired to the draft policy.
  private var header: some View {
    HStack(spacing: 8) {
      Text("Details")
        .font(.headline)

      Spacer(minLength: 8)

      Button(action: requestDismissal) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.ground(.speaker))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Close (Esc)")
      .accessibilityLabel("Close details")
    }
    .padding(.horizontal, CraftTokens.spacing16)
    .padding(.top, CraftTokens.spacing16)
    .padding(.bottom, CraftTokens.spacing12)
  }

  // MARK: The details half (subtitle, chips, facts, tags)

  /// The four parts `DocumentInfoCard` drew, in the same order and at the same
  /// spacing, on a surface that already had the same 380pt measure.
  ///
  /// The order is the card's and the reason is unchanged: the subtitle names
  /// the document, the chips are the one part that *asks* rather than tells,
  /// the facts are about the recording, and the tags are about its content.
  @ViewBuilder
  private var details: some View {
    VStack(alignment: .leading, spacing: Metrics.docHeaderSpacing) {
      if let meta, !meta.subtitle(facts: facts).isEmpty {
        Text(meta.subtitle(facts: facts))
          .font(Tokens.docSubtitleFont)
          .foregroundStyle(.ground(.speaker))
      }

      // The speaker chips — the naming workflow, and the reason the Details
      // button can carry a dot at all.
      if !model.speakerChips.isEmpty {
        SpeakerChipStrip(
          chips: $model.speakerChips,
          onRename: { label, newName in model.renameChip(label: label, newName: newName) },
          onAcceptSuggestion: { label in model.acceptSuggestion(label: label) },
          onDismissSuggestion: { label in model.dismissSuggestion(label: label) }
        )
      }

      if let facts, !facts.isEmpty {
        RecordFactStripView(
          facts: facts,
          // Nil when there are no pips to reach, which makes "N moments" plain
          // text rather than a dead button. The token is on the model because
          // this panel is a sibling of the transcript, not its ancestor.
          onNextMoment: model.openRecordMomentSeconds.isEmpty
            ? nil : { model.nextMomentToken += 1 }
        )
      }

      if let tagEditing {
        EditableTagRow(state: tagEditing)
      } else if let meta, !meta.tags.isEmpty {
        FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
          ForEach(meta.tags, id: \.self) { tag in
            Text(tag)
              .font(Tokens.historyTagFont)
              .foregroundStyle(.ground(.speaker))
              .padding(.horizontal, Metrics.tagPillH)
              .padding(.vertical, Metrics.tagPillV)
              .background(Tokens.tagPillFill, in: Capsule())
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The summary's own chrome, on its own row under the hairline: the Edited
  /// pill, the saving spinner, and Edit / Regenerate (or Cancel / Save while
  /// editing). Everything here used to sit in the panel's header, where it now
  /// would have been a verb aimed at a speaker chip.
  ///
  /// `showsRecordControls` is `SummaryHalf.offersRecordControls`, never a
  /// literal at the call site: a parsed summary has no record behind it, so the
  /// Edited pill, the saving spinner and Edit / Regenerate / Cancel / Save all
  /// name an object that does not exist. They are absent for it — the same call
  /// this row already makes for a record with no narrative — and the label is
  /// all that is left.
  private func summarySectionHeader(showsRecordControls: Bool) -> some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        sectionLabel("Summary")
        if showsRecordControls, record?.isSummaryEdited == true {
          Text("Edited")
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, Metrics.tagPillH)
            .padding(.vertical, Metrics.tagPillV)
            .background(Tokens.primaryActionTint, in: Capsule())
        }
        if showsRecordControls, enrichment.isSavingEdit {
          ProgressView()
            .controlSize(.mini)
        }
      }

      Spacer(minLength: 8)

      if !showsRecordControls {
        EmptyView()
      } else if isEditing {
        Button("Cancel") { cancelEdit() }
          .controlSize(.small)
        Button("Save") { saveEdit() }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(model.summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      } else if hasNarrative {
        // Absent, not greyed out, when there is no narrative. A record with no
        // summary is the ordinary resting state of a transcript-only meeting,
        // and two dead buttons above the live "Generate Summary" — one of them
        // labelled *Re*generate, naming an object that has never existed —
        // read as the summary having been tried and failed.
        Button("Edit") { beginEdit() }
          .controlSize(.small)
          .disabled(isGenerating)
        Button {
          requestRegenerate()
        } label: {
          Label("Regenerate", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
        .disabled(isGenerating)
      }
    }
  }

  // MARK: Content (details → hairline → summary)

  @ViewBuilder
  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        // The hairline is what separates the two halves, so it is drawn only
        // when there are two: a panel opened on a document that carries no
        // metadata at all would otherwise start with a rule under nothing.
        if hasDetails {
          details

          Divider()
            .padding(.vertical, 4)
        }

        switch summaryHalf {
        case .summary:
          summarySectionHeader(showsRecordControls: summaryHalf.offersRecordControls)
          summarySection
            // The Details button's ring fades in and out over the same run
            // (`MainPaneView`, `.animation(Tokens.animFast, value: isGenerating)`),
            // so the panel half reporting that run may not cut (P-B10). Scoped
            // to this subtree and keyed on the activity: the editor lives in
            // here and writes an `@Published` on the model this view observes,
            // so a curve on the panel root — or an unkeyed one — would ride
            // every keystroke of a summary edit.
            .animation(Tokens.animFast, value: enrichment.activity)
        case .parsedSummary:
          // The document's own `## Summary`, read straight out of the markdown
          // in the pane. Read-only, and no run can be in flight against a
          // record that does not exist — so no in-flight fork, no failure
          // caption, and no curve keyed on an activity this half cannot have.
          summarySectionHeader(showsRecordControls: summaryHalf.offersRecordControls)
          parsedSummarySection
        case .noRecordNotice:
          // Nothing behind this document to summarize. Say so, rather than
          // ending at the hairline and letting the absence read as a missing
          // feature.
          Text(Self.noRecordNotice)
            .font(.caption)
            .foregroundStyle(.ground(.speaker))
            .fixedSize(horizontal: false, vertical: true)
        case .waitingForRecord:
          // The record is still being read off disk. Neither half can be drawn
          // honestly yet, and the notice least of all — every recorded
          // transcript passes through this state on open.
          EmptyView()
        }
      }
      .padding(.horizontal, CraftTokens.spacing16)
      .padding(.bottom, CraftTokens.spacing16)
    }
  }

  @ViewBuilder
  private var summarySection: some View {
    if isGenerating {
      inFlightRow
    } else if hasNarrative {
      // Decision 5: a rename/accept on a record that already has a
      // summary leaves the narrative referencing the old label. One-click
      // "Regenerate Summary" until used or dismissed.
      if record?.isSummaryOutdated == true {
        outdatedSummaryBanner
      }

      if isEditing {
        editor
      } else {
        Text(record?.summary?.narrative ?? "")
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          // Remember how tall the narrative reads, so clicking into it
          // opens an editor of the same height instead of jumping to a
          // fixed minimum. A three-line summary should not become a
          // 100pt box under the cursor.
          .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
          } action: { height in
            narrativeHeight = height
          }
          .contentShape(Rectangle())
          .onTapGesture { beginEdit() }
          .help("Click to edit")
      }
      structuredSummary
      errorCaption
    } else {
      generateBlock
    }
  }

  /// The read-only half: the markdown's own narrative, then the same
  /// `structuredSummary` the record's half draws — the three lists are fed
  /// through `keyTopics` / `decisions` / `actionItems`, which fall back to the
  /// parse, so there is one rendering of a topic chip and one of a bullet
  /// however the document was opened.
  ///
  /// The narrative is a plain `Text`: no tap-to-edit, no "Click to edit" help,
  /// and no `narrativeHeight` measurement, because there is no editor for it to
  /// open at the right height. `generateBlock` is not reachable from here
  /// either — it is inside `summarySection`, which this half does not draw.
  @ViewBuilder
  private var parsedSummarySection: some View {
    if let parsed = parsedSummary {
      if !parsed.narrative.isEmpty {
        Text(parsed.narrative)
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      structuredSummary
    }
  }

  /// **The only way to start a summary.** A record with no narrative and
  /// nothing in flight is the ordinary resting state of a transcript-only
  /// meeting now — not a failure, which is what it could only have been while
  /// the button generated on the way in (the old decision 10, and the comment
  /// that used to stand here saying "there is no path to an empty rail").
  ///
  /// It subsumes the old `failureBlock` rather than sitting beside it: a failed
  /// generation lands in exactly this slot, so the message is drawn here and
  /// the button reads Try Again. Two blocks would have meant two Retry buttons
  /// one state apart, and dropping the message would have left a failed summary
  /// offering "Generate Summary" with no word about why the last one did not
  /// land.
  ///
  /// No confirm gate: `requestRegenerate`'s alert protects an *edited* summary,
  /// and a record with no narrative has nothing to edit.
  private var generateBlock: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let message = enrichment.errorMessage, enrichment.errorField == .summary {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.subheadline)
          .foregroundStyle(CraftTokens.failure)
          .lineLimit(3)
      }
      Button(hasSummaryFailure ? "Try Again" : "Generate Summary") {
        enrichment.generateSummary()
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      // Return reaches it. This is the one control in the panel that spends a
      // model call and it is otherwise mouse-only: the panel takes no initial
      // focus, and Escape (the hidden `.cancelAction`) was the only key wired
      // to it. There is no editor in this state to compete for the key — the
      // slot is drawn precisely when there is no narrative to edit.
      .keyboardShortcut(.defaultAction)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }

  /// True when the empty slot is empty *because* something went wrong, which
  /// is the whole difference between "Generate Summary" and "Try Again".
  private var hasSummaryFailure: Bool {
    enrichment.errorMessage != nil && enrichment.errorField == .summary
  }

  private var inFlightRow: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      // No cost estimate: pricing isn't cheaply derivable here, and the T5
      // rule forbids inventing a number — model name only.
      Text(
        "Generating \(enrichment.activity == .tagging ? "tags" : "summary") — \(enrichment.generatingModelID)"
      )
      .font(.subheadline)
      .foregroundStyle(.ground(.speaker))
      Spacer()
      Button("Cancel") {
        // Cancelling leaves the panel exactly where it is. Closing it was
        // right only while the button generated on the way in and an empty
        // panel was unreachable; now the empty state IS a state — the slot
        // holds Generate Summary — and taking the panel down would also take
        // away the chips and facts the owner may have opened it for.
        enrichment.cancelGeneration()
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }

  static let editorMinHeight: CGFloat = 64
  static let editorMaxHeight: CGFloat = 220

  /// What Escape does, in the words of the setting that decides it — the
  /// caption may not promise a commit the `Ask me` policy will not make.
  /// The whole keyboard under the editor, not half of it (P-C12). ⌘↩ is bound
  /// to Save and was named nowhere — the caption explained Escape and stopped,
  /// so the one shortcut that commits an edit was the one nothing said.
  static func escapeCaption(_ behavior: SummaryRailDismissalBehavior) -> String {
    switch behavior {
    case .save: return "⌘↩ saves · Esc closes and saves your changes"
    case .ask: return "⌘↩ saves · Esc closes — you'll be asked about unsaved changes"
    }
  }

  private var escapeCaption: String {
    Self.escapeCaption(model.summaryDismissalBehavior)
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextEditor(text: $model.summaryDraft)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(6)
        // Open at the height the narrative was just reading at (plus the
        // editor's own padding), not at a fixed minimum — swapping a Text for
        // a TextEditor must not move the text under the cursor that clicked
        // it. Floored so a one-line summary is still a usable box, capped so
        // a long one scrolls rather than pushing the rail's chrome off.
        .frame(
          minHeight: min(max(narrativeHeight + 12, Self.editorMinHeight), Self.editorMaxHeight),
          maxHeight: Self.editorMaxHeight
        )
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
        )
        // Escape is the dismissal gesture while editing (decision 13) — it
        // commits under the default setting rather than cancelling the edit.
        //
        // It has to be delivered HERE and not only by the panel's hidden
        // `.cancelAction` button: `TextEditor` is an `NSTextView`, which
        // answers `cancelOperation:` itself and never forwards it to a
        // SwiftUI ancestor. The same trap is documented on the dictation
        // review card, where ⌘↩/Escape need a local key monitor for exactly
        // this reason. With the caret in this editor — the only state where
        // decision 13 means anything — the hidden button is unreachable, so
        // Escape would be a silent no-op underneath a caption promising it
        // works. The hidden button still covers the not-editing case.
        .onExitCommand { requestDismissal() }
      Text(escapeCaption)
        .font(.caption2)
        .foregroundStyle(.ground(.speaker))
    }
  }

  /// One-click regenerate affordance for a record whose summary references
  /// pre-rename speaker labels (decision 5). Regenerate runs the same
  /// confirm-gated path as the header button; the × dismisses the reminder
  /// via the apply-enrichment plumbing (`summaryOutdated: false`).
  private var outdatedSummaryBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.yellow)
      Text("Speaker names changed — the summary still references the old names.")
        .font(.caption)
        .foregroundStyle(.ground(.speaker))
        // Prose wraps; middle truncation is for paths and identifiers (P-D8).
        // At 380pt this sentence always truncated, and `.middle` ate the
        // informative half: "Speaker names chan…the old names."
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .help("Regenerate to update the summary with the renamed speakers")
      Spacer(minLength: 4)
      Button("Regenerate Summary") {
        requestRegenerate()
      }
      .controlSize(.small)
      .help("Regenerate the summary with the updated speaker names")
      Button {
        enrichment.dismissSummaryOutdated()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.ground(.speaker))
          // The glyph is unchanged; the rectangle that takes the click is not
          // the glyph's own bounds any more (P-C3).
          .frame(width: Metrics.chipHitTarget, height: Metrics.chipHitTarget)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Dismiss this reminder")
      .accessibilityLabel("Dismiss summary reminder")
    }
    .padding(.horizontal, Metrics.tagPillH * 2)
    .padding(.vertical, Metrics.tagPillV * 2)
    .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var errorCaption: some View {
    if let message = enrichment.errorMessage, enrichment.errorField == .summary {
      Text(message)
        .font(.caption)
        .foregroundStyle(CraftTokens.failure)
        .lineLimit(2)
    }
  }

  // MARK: Actions

  private func requestRegenerate() {
    if enrichmentNeedsConfirm(record: record, target: .summary) {
      confirmTarget = .summary
    } else {
      enrichment.generateSummary()
    }
  }

  private func beginEdit() {
    model.summaryDraft = record?.summary?.narrative ?? ""
    model.isSummaryEditing = true
  }

  private func cancelEdit() {
    model.isSummaryEditing = false
    model.summaryDraft = ""
  }

  private func saveEdit() {
    let trimmed = model.summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    model.isSummaryEditing = false
    enrichment.saveSummaryEdit(trimmed)
    model.summaryDraft = ""
  }

  // MARK: Structured summary (topics / decisions / action items, read-only)

  // The record first, the document's own parse only when there is no record —
  // `parsedSummary` is nil whenever one exists, so a record that carries a
  // narrative but empty lists still draws empty lists. Unchanged for every
  // document that has a record.
  private var keyTopics: [String] {
    record?.summary?.keyTopics ?? parsedSummary?.keyTopics ?? []
  }
  private var decisions: [String] {
    record?.summary?.decisions ?? parsedSummary?.decisions ?? []
  }
  private var actionItems: [String] {
    record?.summary?.actionItems ?? parsedSummary?.actionItems ?? []
  }

  /// Compact rendering of the record's structured summary fields. Read-only —
  /// the narrative above keeps the only edit affordances. Renders nothing when
  /// all three arrays are empty.
  @ViewBuilder
  private var structuredSummary: some View {
    if !keyTopics.isEmpty {
      topicsBlock
    }
    if !decisions.isEmpty && !actionItems.isEmpty {
      // Two wrapped columns when the pane is wide, stacked when it is narrow.
      // Branches on the MEASURED container width, not ViewThatFits: that keys
      // off ideal (unwrapped single-line) text width, which never fits for
      // sentence-length items and still picks two cramped columns for short
      // ones in a narrow pane. Left exactly as the slot had it (decision 4):
      // at 380pt the rail permanently takes the stacked arm.
      Group {
        if structuredColumnsWidth >= Self.twoColumnMinWidth {
          HStack(alignment: .top, spacing: 18) {
            decisionsColumn
              .frame(maxWidth: .infinity, alignment: .leading)
            actionItemsColumn
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        } else {
          VStack(alignment: .leading, spacing: 12) {
            decisionsColumn
            actionItemsColumn
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { width in
        structuredColumnsWidth = width
      }
      .padding(.top, 4)
    } else if !decisions.isEmpty {
      decisionsColumn
        .padding(.top, 4)
    } else if !actionItems.isEmpty {
      actionItemsColumn
        .padding(.top, 4)
    }
  }

  private var topicsBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Topics")
      FlowLayout(spacing: Metrics.tagSpacing, lineSpacing: Metrics.tagSpacing) {
        // Positional identity: these arrays come verbatim from the LLM and are
        // never deduplicated, so `id: \.self` could collide on a repeated item.
        ForEach(Array(keyTopics.enumerated()), id: \.offset) { _, topic in
          topicChip(topic)
        }
      }
    }
    .padding(.top, 4)
  }

  /// One capsule per key topic: the term on the face, the ` — ` detail (when
  /// present) as a hover tooltip.
  @ViewBuilder
  private func topicChip(_ topic: String) -> some View {
    let parts = topicChipParts(topic)
    // One line always: when FlowLayout clamps an over-wide chip to the row
    // width, the term truncates with an ellipsis instead of wrapping inside
    // the capsule.
    let chip = Text(strippingInlineMarkdown(parts.term))
      .font(.caption)
      .lineLimit(1)
      .padding(.horizontal, 9)
      .padding(.vertical, 3)
      .background(.thinMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(.secondary.opacity(0.3)))
    if let detail = parts.detail {
      chip.help(strippingInlineMarkdown(detail))
    } else {
      chip
    }
  }

  private var decisionsColumn: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Decisions")
      ForEach(Array(decisions.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("•")
            .foregroundStyle(.ground(.timestamp))
          // fixedSize: after the stacked→two-column width flip, a plain Text
          // can keep the narrower layout's cached 2-line height and truncate
          // mid-word; forcing ideal vertical size always shows every line.
          Text(inlineMarkdownAttributed(item))
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var actionItemsColumn: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Action Items")
      ForEach(Array(actionItems.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          // A bullet, not an empty checkbox. A checkbox is an affordance: it
          // says this app tracks whether the item is done, and offers to be
          // clicked. Nota does neither — action items are text the summariser
          // produced and nothing here ever writes a completion back. The same
          // bullet the Decisions column uses says what these are (a list) and
          // promises nothing it cannot keep.
          Text("•")
            .foregroundStyle(.ground(.timestamp))
          Text(inlineMarkdownAttributed(displayActionItem(item)))
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// One section-header style across the two sibling panels (P-D9) — see
  /// `CraftSectionLabel`.
  private func sectionLabel(_ title: String) -> some View {
    CraftSectionLabel(title)
  }

  /// The pipeline writes action items as `[ ] …` checkboxes; the rail renders
  /// them as bullets, so the textual prefix is stripped rather than shown.
  private func displayActionItem(_ item: String) -> String {
    item.hasPrefix("[ ] ") ? String(item.dropFirst(4)) : item
  }
}

// MARK: - The document's own summary (ADR 0006 addendum, 2026-09-02)

/// The four summary fields as the open markdown itself carries them.
///
/// This exists because the summary left the document **body**: `MarkdownRender`
/// used to draw `## Summary` and its three lists, and `SummaryRailView` drew the
/// same four fields off the history record, so every summarized meeting rendered
/// them twice. The body copy went. An imported `.md` has no history record, so
/// with the body copy gone its summary would have been visible nowhere at all —
/// which is precisely the rule ADR 0006 states, that nothing about a document
/// may disappear because of where it was opened from.
///
/// It is deliberately not `EnrichmentSummary`. That type is the record's shape,
/// it decodes from JSON, and half its fields (`title`, `tags`) are answered
/// elsewhere in this panel; a parsed document is four strings-and-lists and
/// nothing that can be written back.
struct ParsedDocumentSummary: Equatable {
  var narrative: String = ""
  var keyTopics: [String] = []
  var decisions: [String] = []
  var actionItems: [String] = []

  /// Nothing was found. The panel keeps its one-line notice for this, rather
  /// than drawing an empty SUMMARY heading over nothing.
  var isEmpty: Bool {
    narrative.isEmpty && keyTopics.isEmpty && decisions.isEmpty && actionItems.isEmpty
  }
}

/// Parse the markdown's own summary block into the four fields the panel draws.
///
/// The headings are `src/pipeline/write.ts`'s, exactly: a meeting emits
/// `## Summary`, `## Key Topics`, `## Decisions Made` and `## Action Items`; a
/// memo emits `## Note` and `## Action Items`. Action items keep their `[ ] `
/// prefix here because the record's copies carry it too — stripping it is
/// `displayActionItem`'s job, and doing it in two places is how the two
/// renderings would come to disagree.
///
/// **It never enumerates the transcript**, which is the whole cost question.
/// `parseDocumentMeta` stops at the *first* `## `; this one starts there and
/// stops at the boundary the writer puts between the summary and the transcript
/// — the `## Full Transcript` heading, or the `---` rule immediately above it.
/// So what is scanned is a header block plus a summary, never a 90-minute
/// meeting, and `enumerateLines` means no line of it is materialized as a
/// `String` after the loop breaks.
///
/// The `---` stop is gated on having already seen a `## ` heading, so a
/// document that opens with YAML front matter is not cut off at its first line.
/// With neither boundary present (an imported `.md` that is not a Nota export)
/// the scan runs to the end and collects nothing, which is the reason for the
/// memo below as well as for the two stops.
func parseDocumentSummary(_ markdown: String) -> ParsedDocumentSummary? {
  enum Section { case none, narrative, topics, decisions, actionItems }

  var section = Section.none
  var sawSection = false
  var narrativeLines: [String] = []
  var parsed = ParsedDocumentSummary()

  markdown.enumerateLines { rawLine, stop in
    let line = rawLine.trimmingCharacters(in: .whitespaces)

    if line.hasPrefix("## ") {
      sawSection = true
      switch String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces) {
      case "Summary", "Note": section = .narrative
      case "Key Topics": section = .topics
      case "Decisions Made", "Decisions": section = .decisions
      case "Action Items": section = .actionItems
      case "Full Transcript": stop = true
      default: section = .none
      }
      return
    }

    // The writer's separator. Everything below it is the transcript.
    if sawSection, line == "---" {
      stop = true
      return
    }

    switch section {
    case .none:
      return
    case .narrative:
      // Raw, so an intentional blank line inside the narrative survives; the
      // block is trimmed once at the end.
      narrativeLines.append(rawLine)
    case .topics:
      if let item = summaryBulletItem(line) { parsed.keyTopics.append(item) }
    case .decisions:
      if let item = summaryBulletItem(line) { parsed.decisions.append(item) }
    case .actionItems:
      if let item = summaryBulletItem(line) { parsed.actionItems.append(item) }
    }
  }

  parsed.narrative = narrativeLines
    .joined(separator: "\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return parsed.isEmpty ? nil : parsed
}

/// `- item` / `* item` → `item`. Nil for anything that is not a list row, so
/// stray prose under a list heading is dropped rather than drawn as a bullet.
private func summaryBulletItem(_ line: String) -> String? {
  for marker in ["- ", "* "] where line.hasPrefix(marker) {
    let item = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    return item.isEmpty ? nil : item
  }
  return nil
}

/// **Parsed once per document, not once per body evaluation.**
///
/// Both halves of the cost rule are honoured, and this is the second one. The
/// parse itself is bounded (it stops at the transcript, above); this one-entry
/// memo then means it runs *once* for an open document rather than on every
/// evaluation of the panel's body — and the panel's own `TextEditor` writes an
/// `@Published` on the model it observes, so "every evaluation" means every
/// keystroke of a summary edit. That is the same trap `parseDocumentMeta`'s
/// `enumerateLines` note records.
///
/// The key is the markdown itself. Comparing it is O(1) in the case that
/// matters — `String.==` short-circuits when both sides are the same storage,
/// and `model.markdown` is one stored property read repeatedly — and a full
/// comparison only happens when the lengths match and the instances differ,
/// i.e. when the document really did change into an equal-length one. Staleness
/// is impossible by construction: equal markdown has an equal parse.
///
/// Main-actor only in practice (it is read from a SwiftUI body), which is why
/// there is no lock: two views of one document on one actor is the whole
/// audience.
enum DocumentSummaryCache {
  private static var key = ""
  private static var value: ParsedDocumentSummary?

  /// How many parses have actually run — so the memo is a fact a test can
  /// check rather than a claim in a comment.
  private(set) static var parseCount = 0

  static func summary(for markdown: String) -> ParsedDocumentSummary? {
    if markdown == key { return value }
    let parsed = parseDocumentSummary(markdown)
    key = markdown
    value = parsed
    parseCount += 1
    return parsed
  }
}
