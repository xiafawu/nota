import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainPaneView: View {
  /// The live dictation session lives on the model (single owner); the pane
  /// reads it from the environment and never owns session state itself.
  @EnvironmentObject private var model: NotaModel
  /// Observed directly (not via the model) so the local cluster's Details
  /// button re-renders on generation progress and failures without
  /// re-rendering the whole pane.
  @ObservedObject private var enrichment = EnrichmentController.shared
  let content: MainPaneContent
  @Binding var isDropTargeted: Bool
  /// Still here after the chips moved into the Details panel: the transcript
  /// echoes each chip's identity hue onto its speaker runs
  /// (`applySpeakerColors`), and the Details button's dot reads them.
  @Binding var speakerChips: [SpeakerChip]
  let onDropURL: (URL) -> Void

  var body: some View {
    ZStack {
      switch content {
      case .empty(let state):
        EmptyMainView(state: state, isDropTargeted: isDropTargeted)
          // A run in progress is the transcript arriving, so it wears the
          // transcript's ground: this pane becomes the document without the
          // window changing, and a ground that switched underneath at the
          // moment the text landed would read as a second event.
          .background(FieldBackground(role: .transcript))
      case .rich(let document):
        RichDocumentPane(
          document: document,
          speakerChips: $speakerChips,
          // XIA-429: the moments come off the open record, through the model,
          // so the gutter pips answer to the same scan the drawer row does.
          markerSeconds: model.openRecordMomentSeconds,
          // Reserved only while a receipt is really up. A document with nothing
          // in flight owes it nothing, and reserving unconditionally would take
          // a band off every transcript for a surface most of them never show.
          bottomReserve: receiptIsUp ? RecordReceiptMetrics.documentBottomReserve : 0,
          nextMomentToken: model.nextMomentToken
        )
        // The ground reaches the two panes that never had one. It is attached
        // per branch rather than to this `ZStack`, because `.liveMeeting` draws
        // its own inside `LiveMeetingView` — one here as well would stack two
        // full-window image layers for the one that can only ever show the top.
        //
        // `RichTextViewer` already sets `drawsBackground = false` on both the
        // scroll view and the text view, so the transcript was built to sit
        // over something and had been falling through to the window material.
        .background(FieldBackground(role: .transcript))
      case .liveMeeting:
        LiveMeetingView(
          session: model.liveSession,
          kind: model.activeSessionKind,
          isStarting: model.isStartingLiveSession,
          // The **kind**, not the default. This closure is both the idle Start
          // button and the failure banner's Try Again, and `startLiveSession()`
          // defaults to `.meeting` — so a failed memo retried from the window
          // came back as a meeting (wrong kind on the record, wrong
          // diarize/identify flags) while the same press on the island came back
          // as a memo. The pane already names `activeSessionKind` in its own
          // copy, so honouring it is what this state was already saying.
          onStart: { model.startLiveSession(kind: model.activeSessionKind) },
          onStop: { model.stopLiveSession() },
          onDiscard: { model.discardLiveSession() },
          discardAudioBytes: { model.liveRecordingAudioBytes() },
          // One verb for every surface that offers Mark (XIA-434): the pane's
          // capsule, the island's, and the menu bar's row all land here.
          onMark: { _ = model.markCurrentMoment() },
          // One capsule, two verbs, resolved by the model off the session's own
          // state (XIA-447) — for the reason Mark is one closure here.
          onPause: { model.toggleLivePause() },
          markerLog: model.sessionMarkers,
          markersUnsaved: model.markersUnsaved
        )
      }

      if isDropTargeted, acceptsDrop {
        DropTargetStroke()
      }

      // Bottom-right local cluster (ADR 0005): per-transcript actions float
      // over the content area, inset from its trailing and bottom edges —
      // never pinned to the window frame. Details + Share, and Details shows
      // for every rich document — an imported `.md` with no history record
      // included. Nothing about a document may silently disappear because it
      // was opened from a different source; the panel says what it has and
      // states, in a line, that this file has no record behind it.
      if isRichContent {
        localCluster
      }

      // WHAT STOP LOOKS LIKE (XIA-429). The receipt rises in the capsule
      // cluster's exact footprint and IS the processing surface: it is up
      // exactly while this document's record is still being worked on, and what
      // it says survives it in the header's fact strip.
      //
      // The slot observes the ledger, not this pane: the ledger ticks once a
      // second and `MainPaneView` is the whole document — the XIA-432 trap is
      // that a publisher's rate and its observers' breadth multiply. What
      // crosses back out is one Bool, changing at most twice a session.
      if isRichContent, let facts = model.openRecordFacts, let output = model.lastOutputURL {
        RecordReceiptSlot(
          facts: facts,
          outputPath: output.standardizedFileURL.path,
          onRetry: { model.retryOpenDocumentSummary() },
          onNextMoment: model.openRecordMomentSeconds.isEmpty ? nil : { model.nextMomentToken += 1 },
          onVisibilityChange: { receiptIsUp = $0 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, RecordReceiptMetrics.bottomInset)
        .allowsHitTesting(true)
      }
    }
    .animation(Tokens.animSnap, value: isDropTargeted)
    .animation(Tokens.animFast, value: isRichContent)
    // P-C9: a live session refuses the drop rather than queueing it. Binding
    // `isTargeted` to a constant is what keeps the accept stroke off the
    // screen — a target that lights up over a running meeting promises to
    // accept a file the surface would then hide, and `performAccept` would
    // clear the open document and start a second pipeline behind the live
    // phase.
    .onDrop(
      of: [UTType.fileURL.identifier],
      isTargeted: acceptsDrop ? $isDropTargeted : .constant(false)
    ) { providers in
      guard acceptsDrop else { return false }
      guard let provider = providers.first else {
        return false
      }

      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url: URL?
        if let data = item as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else if let nsURL = item as? NSURL {
          url = nsURL as URL
        } else {
          url = nil
        }

        if let url {
          Task { @MainActor in
            onDropURL(url)
          }
        }
      }
      return true
    }
  }

  /// True while a receipt is on screen. Set by the slot (which is what watches
  /// the ledger) and read by the transcript, which owes the receipt its
  /// footprint while it is up and owes it nothing when it is not.
  @State private var receiptIsUp = false

  private var isRichContent: Bool {
    if case .rich = content { return true }
    return false
  }

  /// Whether this pane may take a dropped file at all (P-C9).
  private var acceptsDrop: Bool {
    MainPaneDrop.accepts(content: content, isStartingLiveSession: model.isStartingLiveSession)
  }

  /// The bottom-right local cluster: Details (one button, 2026-08-19) and
  /// Share (decision 11 — the toolbar's ShareMenu reused as-is, host only).
  /// Two individual round glass buttons, icon-only with tooltips (ADR 0005),
  /// floating over the content, inset from its trailing and bottom edges.
  /// The label box every cluster button draws into. Fixing the *label* rather
  /// than the control is what keeps the two buttons the same size: the glass
  /// button style adds its own padding around whatever it is given, so two
  /// labels of different widths (an icon and the word "Share") produce two
  /// differently shaped controls — which is exactly what a reused toolbar
  /// `Label` did here before.
  static let clusterGlyphSize: CGFloat = 17

  private var localCluster: some View {
    // A `GlassEffectContainer` is what makes two adjacent plates read as one
    // cluster: it merges their lensing rather than letting each refract
    // independently, which is the difference between a pair of controls and
    // two unrelated bubbles that happen to be near each other. A toolbar gets
    // this for free; a hand-placed pair has to ask.
    GlassEffectContainer(spacing: CraftTokens.spacing8) {
      HStack(spacing: CraftTokens.spacing8) {
        detailsClusterButton
        ShareMenu(model: model, style: .localCluster)
      }
    }
    .padding(.trailing, CraftTokens.spacing16)
    .padding(.bottom, CraftTokens.spacing16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
  }

  /// **One button, called Details** (2026-08-19). It opens the one panel that
  /// holds everything about this document — the subtitle, the speaker chips,
  /// the record's facts, the tags, and the summary.
  ///
  /// What went with the merge is the *dual-purpose click* (the old decision
  /// 10): with no summary, one press used to start a generation AND open the
  /// rail to watch it. Opening is free now. A press costs nothing, reverses
  /// with a second press, and spends no model call — which is what a control
  /// has to be before the whole of a document's metadata can be put behind it.
  /// Generation moved *inside* the panel, into the slot where the narrative
  /// would be, so the one thing that spends money is a button that says so.
  ///
  /// The `plus` glyph went with it: it was the promise of that click. The ring
  /// stays and still means a **summary** generation specifically (a tag run is
  /// another lane and must not spin it), because the panel it opens is where
  /// the Cancel for it lives.
  ///
  /// `.disabled` went too, and that is the one deletion nobody asked for by
  /// name: it existed because the click could start a summary. A tag run is no
  /// reason to lock the owner out of their own speaker chips.
  private var detailsClusterButton: some View {
    let isGenerating = enrichment.activity == .summarizing
    let waiting = DocumentInfoBadge.waiting(
      chips: speakerChips,
      isSummaryOutdated: enrichment.record?.isSummaryOutdated == true
    )

    return Button {
      model.isSummaryRailPresented = true
    } label: {
      // One glyph-sized label in every state, so the glass button style keeps
      // one size — the ring in particular must not resize the control
      // mid-generation.
      ZStack {
        if isGenerating {
          ProgressView().controlSize(.small)
        } else {
          Image(systemName: "info.circle")
            .imageScale(.medium)
        }
      }
      .frame(width: Self.clusterGlyphSize, height: Self.clusterGlyphSize)
    }
    // Real Liquid Glass from the button style, not a hand-drawn
    // `Circle().fill(.thinMaterial)`: a material is a blur, glass refracts,
    // and only the style carries the hover and pressed states.
    //
    // Prominent means the panel is OPEN — the ordinary toolbar-toggle idiom,
    // and now literally true of one surface: the control is lit exactly while
    // the thing it opens is on screen.
    .localClusterButton(prominent: model.isSummaryRailPresented)
    // ONE dot, for two claimants (`DocumentInfoBadge`): a waiting speaker
    // suggestion, a stale summary, or both. It rides OUTSIDE the style's shape
    // so the glass does not blur it and the button's own size is unchanged by
    // it — the rule the old stale dot and the old info toggle's dot both kept,
    // with the same 9pt geometry, because they are now the same dot.
    .overlay(alignment: .topTrailing) {
      if waiting != nil {
        Circle()
          .fill(.yellow)
          .frame(width: 9, height: 9)
          .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1))
          .offset(x: 2, y: -2)
          .allowsHitTesting(false)
      }
    }
    .animation(Tokens.animFast, value: isGenerating)
    .animation(Tokens.animFast, value: waiting)
    .animation(Tokens.animFast, value: model.isSummaryRailPresented)
    // One string for both, so the tooltip and VoiceOver can never disagree
    // about which decision is waiting — and it names the ring too. The
    // `accessibilityLabel` here replaces the `ProgressView` child's own
    // announcement, so without the generating clause a non-sighted owner is
    // told "Details" whether or not the summary they started is still running:
    // the ring would be the sole feedback for the press, and it is pixels.
    .help(DocumentInfoBadge.label(waiting, isGeneratingSummary: isGenerating))
    .accessibilityLabel(DocumentInfoBadge.label(waiting, isGeneratingSummary: isGenerating))
  }

  /// Echo each chip's identity hue onto its transcript speaker runs. Speaker
  /// runs are the "Name: " prefixes rendered in `NSFonts.speaker` that carry a
  /// `.notaTimestamp` attribute (see MarkdownRender), which keeps generic bold
  /// text untouched.
  static func applySpeakerColors(
    to body: NSAttributedString,
    chips: [SpeakerChip]
  ) -> NSAttributedString {
    guard !chips.isEmpty, body.length > 0 else { return body }

    var colorForName: [String: NSColor] = [:]
    for (index, chip) in chips.enumerated() {
      let display = chip.name.isEmpty ? chip.label : chip.name
      colorForName[display] = SpeakerColors.nsColor(at: index)
    }

    let output = NSMutableAttributedString(attributedString: body)
    let fullRange = NSRange(location: 0, length: output.length)
    let text = output.string as NSString
    output.enumerateAttributes(in: fullRange) { attributes, range, _ in
      guard
        attributes[.notaTimestamp] != nil,
        let font = attributes[.font] as? NSFont,
        // The reading scale (XIA-441) renamed this face; the run is still
        // found by matching the font the renderer used for a speaker name.
        font == NSFonts.readingSpeaker
      else {
        return
      }
      let run = text.substring(with: range)
      guard run.hasSuffix(": ") else { return }
      let name = String(run.dropLast(2))
      guard let color = colorForName[name] else { return }
      output.addAttribute(.foregroundColor, value: color, range: range)
    }
    return output
  }
}

// MARK: - Rich document pane (header + transcript)

private struct RichDocumentPane: View {
  let document: DocumentRender
  /// Read only to colour the transcript's speaker runs. The chips themselves
  /// are drawn by the Details panel now, so nothing here renames them.
  @Binding var speakerChips: [SpeakerChip]
  /// The seconds its moments were flagged at — the gutter pips.
  var markerSeconds: [TimeInterval] = []
  /// What the receipt is occupying at the bottom, if one is up. Comes off the
  /// **scroll view's own frame**, which is the only inset that moves where a
  /// scroll comes to rest (the lesson `transcriptBottomReserve` is built on).
  var bottomReserve: CGFloat = 0
  /// Bumped by the fact strip's "N moments" button, which now lives in the
  /// Details panel — a sibling overlay in ContentView, not this view tree, so
  /// the token is on `NotaModel` and arrives here as a plain value.
  var nextMomentToken: Int

  /// True once the rich-text body has scrolled under the header; drives the
  /// top fade on the body and **nothing else**.
  ///
  /// It used to drive the header's collapse too, which is where the shake came
  /// from: collapsing changed the header's height, which changed the scroll
  /// range that had decided to collapse it. A fade changes no layout, so this
  /// offset can no longer feed back into itself.
  @State private var isBodyScrolled = false

  var body: some View {
    VStack(spacing: 0) {
      if let meta = document.meta {
        // The title, and nothing else. Everything that used to sit under it —
        // and then sat in an overlay card hung off this body — is in the
        // Details panel, one press away in the local cluster.
        DocumentHeaderView(meta: meta)
        // Not a `Divider()`: that is `separatorColor`, and this hairline sits on
        // the `.transcript` ground with the reading column under it, where the
        // `---` rule already draws at the measured `.rail` tier
        // (`MarkdownRender`). The recording pane made this exact argument for
        // its own rail before that rail was deleted with the bar.
        Rectangle()
          .fill(.ground(.rail))
          .frame(height: 1)
      }
      // Decision 29: nothing sits between the header and the transcript —
      // the enrichment slot is gone, the summary lives in the rail overlay.
      RichTextViewer(
        attributedString: MainPaneView.applySpeakerColors(to: document.body, chips: speakerChips),
        onScroll: { offset in
          let scrolled = offset > Metrics.docBodyFadeThreshold
          guard scrolled != isBodyScrolled else { return }
          // A plain assignment: `.animation(Tokens.animFast, value:
          // isBodyScrolled)` below is the one authority for this change. A
          // `withAnimation` here duplicated it and, worse, leaked its
          // transaction to everything else re-evaluated in the same update —
          // the receipt, the drop border, the local cluster — so a surface
          // arriving at the moment the reader scrolls would fade on the
          // scroll's curve rather than its own (P-B5).
          isBodyScrolled = scrolled
        },
        markerSeconds: markerSeconds,
        nextMomentToken: nextMomentToken
      )
      .mask(bodyFadeMask)
      .padding(.bottom, bottomReserve)
      // The reserve is reported from the receipt's `onAppear`/`onDisappear`,
      // which fire at the *start* of the 0.2s fade they are timing — so the
      // scroll geometry used to step while the receipt was still half
      // transparent. Travelling on the same curve keeps the transcript's
      // footprint and the surface floating over it in agreement, which is the
      // whole of the XIA-429/XIA-445 reservation argument (P-B11). Keyed on the
      // reserve itself, so the transaction reaches this subtree and no further.
      .animation(Tokens.animFast, value: bottomReserve)
    }
    .animation(Tokens.animFast, value: isBodyScrolled)
  }

  /// Scroll-edge fade: once content scrolls beneath the header, the top of the
  /// body dissolves instead of hard-clipping against the hairline. Fixed-height
  /// gradient — a percentage gradient would scale with document height.
  private var bodyFadeMask: some View {
    VStack(spacing: 0) {
      LinearGradient(
        colors: [
          .black.opacity(isBodyScrolled ? Tokens.docBodyFadeGhostOpacity : 1),
          .black,
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .frame(height: Metrics.docBodyTopFadeHeight)
      Rectangle().fill(Color.black)
    }
  }
}

#if DEBUG
#Preview("empty idle") {
  MainPaneView(
    content: .empty(PreviewMocks.emptyMainIdle),
    isDropTargeted: .constant(false),
    speakerChips: .constant([]),
    onDropURL: { _ in }
  )
  .environmentObject(NotaModel())
  .frame(width: 720, height: 540)
}

#Preview("empty targeted") {
  MainPaneView(
    content: .empty(PreviewMocks.emptyMainIdle),
    isDropTargeted: .constant(true),
    speakerChips: .constant([]),
    onDropURL: { _ in }
  )
  .environmentObject(NotaModel())
  .frame(width: 720, height: 540)
}

#Preview("rich content") {
  MainPaneView(
    content: .rich(PreviewMocks.sampleDocument),
    isDropTargeted: .constant(false),
    speakerChips: .constant([]),
    onDropURL: { _ in }
  )
  .environmentObject(NotaModel())
  .frame(width: 720, height: 540)
}

#Preview("live meeting idle") {
  MainPaneView(
    content: .liveMeeting,
    isDropTargeted: .constant(false),
    speakerChips: .constant([]),
    onDropURL: { _ in }
  )
  .environmentObject(NotaModel())
  .frame(width: 720, height: 540)
}
#endif

// MARK: - Drop decisions and the stroke both phases draw (P-C9 / P-C10)

/// Whether the main pane may accept a dropped audio file, as a pure decision —
/// the way `LivePhaseGate` and `StopLanding` are (P-C9).
///
/// A live meeting refuses. Accepting one runs `performAccept` → `transcribe()`,
/// which clears the open document and starts a second pipeline behind a pane
/// the live phase pins in front, and `performTranscribe` guards only
/// `!isRunning`. `isStartingLiveSession` is refused for the same reason: a
/// Start press is accepted the instant it is seen, and the seconds-long start
/// window is exactly when a stray drop would land.
enum MainPaneDrop {
  static func accepts(content: MainPaneContent, isStartingLiveSession: Bool) -> Bool {
    if isStartingLiveSession { return false }
    if case .liveMeeting = content { return false }
    return true
  }
}

/// The full-bleed accept stroke. One view, so the home phase and the three
/// pane phases cannot draw the same gesture at two radii (P-C10).
struct DropTargetStroke: View {
  var body: some View {
    RoundedRectangle(cornerRadius: Self.cornerRadius)
      .strokeBorder(Tokens.dropAccent, lineWidth: Self.strokeWidth)
      .allowsHitTesting(false)
      .transition(.opacity)
  }

  static let cornerRadius: CGFloat = Metrics.dropFullBleedCornerRadius
  static let strokeWidth: CGFloat = Metrics.dropTargetStrokeWidth
}
