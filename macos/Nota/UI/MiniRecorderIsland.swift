import AppKit
import SwiftUI

// MARK: - What the island is

/// The mini-recorder island (XIA-434): one ~320×44 floating capsule that says a
/// session is running when the window that would have said it is not in front.
///
/// **It carries no transcript, ever.** The words are the window's job; the
/// island's job is the three facts you need when you are looking at something
/// else — the microphone is open, this is how long it has been, and here is how
/// to flag a moment or stop. That is also why the card is a hard, constant size:
/// nothing the session says may grow it, so there is nothing for a long turn to
/// push around. The components are the recording surface's own
/// (`SessionMeter`, `SessionTimer`) rather than smaller copies of them, which is
/// what keeps a glance at the island and a glance at the window agreeing.

// MARK: - Phase

/// What the island is showing. Four states, one card.
///
/// A phase carries only *derived strings* — never a transcript, never a segment
/// — which is what makes "no transcript, ever" a fact about the type rather than
/// a promise about a view body.
enum MiniIslandPhase: Equatable {
  /// The microphone is open: dot, meter, clock, Mark, Stop.
  case recording
  /// A ⌘K just landed. Replaces the controls for
  /// `MiniIslandVisibility.markConfirmationDuration` and nothing else moves —
  /// the dot, the meter and the clock stay exactly where they are, because the
  /// microphone did not stop being open while the island congratulated itself.
  ///
  /// `landed` is whether the press reached the **record**, not whether it
  /// reached the log. A ⌘K whose write failed (a full disk, a record made
  /// unwritable mid-meeting) keeps the moment in memory and says so, because a
  /// card that congratulates the owner four times over a record holding none of
  /// them is worse than a card that says nothing. The pane draws the same fact
  /// through `NotaModel.markersUnsaved`, and the pane is by construction not on
  /// screen whenever the island is.
  case markConfirmed(time: String, ordinal: String, landed: Bool)
  /// The owner pressed Pause (XIA-447). The session is still theirs and the
  /// card **says so in words** — the dot goes grey, the meter goes, the clock
  /// holds at the audio time it reached, and the card reads "Paused". A card
  /// that only went quiet is a card that reads as a session that ended, which
  /// is the whole failure this state is worded to prevent.
  case paused
  /// Stop has been pressed and the record is being worked on somewhere else.
  case handoff(secondsAgo: Int)
  /// The session dropped. Names what failed and that the audio is being kept.
  case failure(String)

  /// Whether this phase draws the ember dot and the live meter.
  ///
  /// `CraftTokens.ember(_:)` means the microphone is open and nothing else, so
  /// only the two phases that can only be reached with a live microphone answer
  /// true — see `MiniIslandVisibility.phase(_:)`, which gates both behind
  /// `LiveMeetingSession.meterFollowsMicrophone`.
  var showsEmber: Bool {
    switch self {
    case .recording, .markConfirmed: return true
    case .paused, .handoff, .failure: return false
    }
  }

  /// Whether the clock is drawn. **Not** the same set as the ember any more:
  /// a paused session's clock is the length of the recording so far, which is
  /// still true and still the owner's — it has simply stopped moving. What has
  /// stopped meaning anything is an elapsed time beside a session that is over.
  var showsClock: Bool {
    switch self {
    case .recording, .markConfirmed, .paused: return true
    case .handoff, .failure: return false
    }
  }

  /// What the owner may do from here. A table rather than branches in a view
  /// builder, for the reason `SessionClusterAction` is one: which control does
  /// what is exactly the thing that shipped wrong on the cluster, and a table is
  /// a fact a test reads.
  var actions: [MiniIslandAction] {
    switch self {
    case .recording: return [.mark, .pause, .stop]
    // Mark is gone rather than disabled, for the reason the confirmation's list
    // is empty rather than disabled: `NotaModel.markCurrentMoment` refuses a
    // paused session, so a Mark capsule here would be a control that does
    // nothing at all. Resume and Stop are both live — Stop is terminal from
    // here too, and the owner may not have to resume in order to end.
    case .paused: return [.resume, .stop]
    // The confirmation *replaces* the controls; that is the whole of what
    // "replacing" means and it is why this list is empty rather than disabled.
    case .markConfirmed: return []
    case .handoff: return [.show]
    // **Show comes first, and Try Again is not the only way out.** A failed
    // session keeps everything it heard, and the route to that transcript is
    // the window's banner (`LiveMeetingControls.saveOrDiscard` → Save
    // Transcript). Try Again settles the leftover record through
    // `LiveSessionOwner.start`, which writes a `failed(stage:)` status and
    // never seals a transcript — so an island offering Try Again alone would
    // hand the owner one button that throws away forty minutes of realtime
    // transcript, on a card whose own copy just told them things were kept.
    case .failure: return [.show, .retry]
    }
  }

  /// The line of text this phase puts beside (or instead of) the clock.
  var message: String? {
    switch self {
    case .recording: return nil
    case .paused: return RecordingPaneCopy.pausedTitle
    case .markConfirmed(let time, let ordinal, let landed):
      return MiniIslandCopy.marked(time: time, ordinal: ordinal, landed: landed)
    case .handoff(let secondsAgo): return MiniIslandCopy.handoff(secondsAgo: secondsAgo)
    case .failure(let message): return MiniIslandCopy.failure(message)
    }
  }
}

/// The four things an island button can do.
enum MiniIslandAction: CaseIterable {
  /// Flag this instant — the same press ⌘K makes in the window.
  case mark
  /// Stop capturing, keep the session (XIA-447).
  case pause
  /// Continue into the same recording.
  ///
  /// Two cases rather than one with a face that changes, unlike the window
  /// cluster's single `.pause`: the island's row is built per **phase**, so
  /// exactly one of these is ever offered and "which control does what" stays
  /// one verb per case — the property `IslandVerbs` exists to keep.
  case resume
  /// End the session and hand it off. Terminal: no resume follows a Stop.
  case stop
  /// Bring Nota forward onto the record that is being worked on.
  case show
  /// Start again after a failure. The failed session's own audio and
  /// transcript are untouched by this (XIA-430); nothing here deletes.
  case retry

  var symbol: String {
    switch self {
    case .mark: return "bookmark.fill"
    case .pause: return "pause.fill"
    case .resume: return "play.fill"
    case .stop: return "stop.fill"
    case .show: return "arrow.up.forward.app.fill"
    case .retry: return "arrow.clockwise"
    }
  }

  /// An icon-only control's only name.
  var label: String {
    switch self {
    case .mark: return RecordingPaneCopy.markTitle
    case .pause: return RecordingPaneCopy.pauseTitle
    case .resume: return RecordingPaneCopy.resumeTitle
    case .stop: return RecordingPaneCopy.stopTitle
    case .show: return MiniIslandCopy.showTitle
    case .retry: return MiniIslandCopy.retryTitle
    }
  }

  var help: String {
    self == .mark ? RecordingPaneCopy.markHelp : label
  }

  /// Blue for a confident action, red for the one that ends the session — the
  /// cluster's vocabulary, unchanged, because the island is the cluster seen
  /// from another room. The ember is deliberately not a button colour anywhere:
  /// it belongs to the dot and the meter.
  var tint: Color {
    self == .stop ? CraftTokens.stopRed : CraftTokens.primaryBlue
  }

  /// Only Mark carries a keyboard shortcut, and it is the window's ⌘K.
  ///
  /// It is read by the **menu bar's** row, not by the island's own button: the
  /// island panel never becomes key (`MiniRecorderPanel.canBecomeKey` is false,
  /// deliberately — it must not take keystrokes off the app the owner is
  /// working in), so a `.keyboardShortcut` on a capsule there would be a
  /// shortcut that can never fire, advertised in a tooltip. The island's Mark is
  /// a click; ⌘K is the window's and the menu's.
  var shortcut: KeyboardShortcut? {
    self == .mark ? KeyboardShortcut("k", modifiers: .command) : nil
  }

  /// The accessibility hint for a row that binds a key — "Mark ⌘K", the same
  /// string the cluster's capsule uses (P-C12). Empty for a row with no
  /// shortcut, so a row never announces a key it does not bind.
  var shortcutHint: String {
    self == .mark ? RecordingPaneCopy.markShortcut : ""
  }
}

// MARK: - Copy

/// Every fixed string the island can draw, in one place — the discipline
/// `RecordingPaneCopy` established.
enum MiniIslandCopy {
  static let showTitle = "Show"
  static let retryTitle = "Try Again"

  /// "Marked 28:40 · 3rd", and "Marked 28:40 · 3rd · not saved" when the write
  /// did not reach the record.
  static let markUnsavedClause = "not saved"

  static func marked(time: String, ordinal: String, landed: Bool = true) -> String {
    let confirmation = "Marked \(time) · \(ordinal)"
    return landed ? confirmation : "\(confirmation) · \(markUnsavedClause)"
  }

  /// "1st", "2nd", "3rd", "11th", "21st". English, because it is read as
  /// English — a bare "3" beside a timestamp reads as another number.
  static func ordinal(_ n: Int) -> String {
    guard n > 0 else { return "\(n)" }
    let suffix: String
    switch (n % 100, n % 10) {
    case (11, _), (12, _), (13, _): suffix = "th"
    case (_, 1): suffix = "st"
    case (_, 2): suffix = "nd"
    case (_, 3): suffix = "rd"
    default: suffix = "th"
    }
    return "\(n)\(suffix)"
  }

  /// "Transcribing… just now" / "Transcribing… 3s ago".
  ///
  /// The age is named rather than a spinner because the island is up precisely
  /// when the owner is doing something else: "still going" is the question, and
  /// a rotating glyph answers it with no scale.
  static func handoff(secondsAgo: Int) -> String {
    secondsAgo <= 0 ? "Transcribing… just now" : "Transcribing… \(secondsAgo)s ago"
  }

  /// The session's own failure message, with the one fact the owner most needs
  /// and would not otherwise believe: **the audio is being kept.** Nothing in
  /// Nota deletes a recording on a failure path (XIA-430/XIA-436), and a
  /// floating red card that said only "Connection lost" would read as a session
  /// thrown away.
  static let audioSavingClause = "audio saving"

  /// The longest a failure message may be before this card cuts it.
  ///
  /// **The clamp is what makes "no transcript, ever" structural.** The string
  /// comes off `LiveMeetingSession.SessionState.failed(_:)`, which is whatever
  /// the realtime path had to say — and a server payload or a quoted turn is a
  /// sentence somebody spoke arriving on the one surface that may not carry
  /// one. Truncating in the view would hide it on screen and still have let the
  /// *type* carry it, which is precisely the hole
  /// `testNoPhaseCanCarryTranscript` was passing through.
  static let failureMessageLimit = 40

  static func clamp(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    return text.prefix(max(limit - 1, 0)).trimmingCharacters(in: .whitespaces) + "…"
  }

  static func failure(_ message: String) -> String {
    let trimmed = clamp(
      message
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines),
      to: failureMessageLimit
    )
    guard !trimmed.isEmpty else { return "Recording failed — \(audioSavingClause)" }
    guard !trimmed.lowercased().contains(audioSavingClause) else { return trimmed }
    return "\(trimmed) — \(audioSavingClause)"
  }

  /// Every string the island can put on screen for one phase. The test that
  /// holds "no transcript reaches this surface" reads it.
  static func all(_ phase: MiniIslandPhase) -> [String] {
    var strings = phase.message.map { [$0] } ?? []
    strings.append(contentsOf: phase.actions.map(\.label))
    return strings
  }
}

// MARK: - The visibility rule

/// A ⌘K the island has just acknowledged.
struct MiniIslandMark: Equatable {
  /// Seconds into the session, as the mark itself records them.
  let at: TimeInterval
  /// Which moment of the session this was — 1 for the first.
  let ordinal: Int
  /// Whether the press reached the record on disk. False makes the card say so.
  var landed: Bool = true
  /// When the press happened, on the same clock `MiniIslandVisibility` is asked
  /// with (`ProcessInfo.processInfo.systemUptime` in production, an injected
  /// number in tests).
  let pressedAt: TimeInterval
}

/// Everything the visibility rule is allowed to look at.
struct MiniIslandInputs {
  var sessionState: LiveMeetingSession.SessionState = .idle
  /// Read at decision time and never cached — the owner may have switched away
  /// since the last one (the rule `CompletionNotifier.appIsFrontmost` already
  /// keeps).
  var appIsFrontmost: Bool = false
  var mark: MiniIslandMark?
  /// When Stop was pressed, or nil if it has not been.
  var handoffStartedAt: TimeInterval?
  var now: TimeInterval = 0
}

/// Whether the island is up, and as what — the whole of the rule, pure.
///
/// **Two live indicators for one microphone is the mistake `isReviewing`
/// already taught this codebase**, so the frontmost check is first and applies
/// to every phase without exception: bringing Nota forward takes the island
/// down whatever it was showing, because the window is then saying the same
/// thing better.
enum MiniIslandVisibility {
  /// How long "Marked 28:40 · 3rd" stands in for the controls.
  static let markConfirmationDuration: TimeInterval = 2
  /// How long the post-Stop handoff card lingers before it goes by itself. The
  /// menu bar's warm slot (`ProcessingMenuBarLabel`) carries the rest of the
  /// work, so this is a hand-off notice and not a progress window.
  static let handoffWindow: TimeInterval = 8

  static func phase(_ inputs: MiniIslandInputs) -> MiniIslandPhase? {
    // One rule, before everything: Nota in front means the island is off.
    guard !inputs.appIsFrontmost else { return nil }

    // The handoff outranks the state it leaves behind. Stopping a *failed*
    // session (Save Transcript) is a real path, and for those few seconds the
    // record is being sealed — which is what the owner just asked for and not
    // the failure they already read.
    if let startedAt = inputs.handoffStartedAt {
      let age = inputs.now - startedAt
      if age >= 0, age < handoffWindow {
        return .handoff(secondsAgo: Int(age))
      }
    }

    if case .failed(let message) = inputs.sessionState {
      return .failure(message)
    }

    // **Above the microphone gate, deliberately** (XIA-447). Everything below
    // is gated on `meterFollowsMicrophone`, which a paused session fails — so
    // resolved down there the island would go off screen entirely the moment
    // the owner pressed Pause, in the one situation where they are looking at
    // another app and the window cannot tell them anything.
    if inputs.sessionState == .paused {
      return .paused
    }

    // The ember phases, and the only gate on them: the microphone is open.
    // `.stopping` deliberately does not qualify — the tap is still installed
    // but every buffer is dropped, and an island answering a voice that is not
    // being recorded is the exact lie the meter exists to make impossible.
    guard LiveMeetingSession.meterFollowsMicrophone(inputs.sessionState) else { return nil }

    if let mark = inputs.mark {
      let age = inputs.now - mark.pressedAt
      if age >= 0, age < markConfirmationDuration {
        return .markConfirmed(
          time: LiveMeetingFormat.duration(mark.at),
          ordinal: MiniIslandCopy.ordinal(mark.ordinal),
          landed: mark.landed
        )
      }
    }

    return .recording
  }

  /// When the next scheduled change is due, so the controller can wake for it
  /// rather than polling forever. Nil when nothing in flight expires.
  static func nextDeadline(_ inputs: MiniIslandInputs) -> TimeInterval? {
    var deadlines: [TimeInterval] = []
    if let mark = inputs.mark { deadlines.append(mark.pressedAt + markConfirmationDuration) }
    if let startedAt = inputs.handoffStartedAt {
      // The handoff card counts its own age, so it needs a tick a second.
      deadlines.append(min(startedAt + handoffWindow, inputs.now + 1))
    }
    return deadlines.filter { $0 > inputs.now }.min()
  }
}

// MARK: - Metrics

/// The island's geometry, as arithmetic — the split `SessionTimerMetrics` and
/// `RecordingPaneMetrics` already established, so "how tall is the island" is
/// answered without a window server.
///
/// The height is **derived from the tallest thing the island holds**, never
/// typed beside it. That is the XIA-444 warning verbatim: `controlRowHeight`
/// was written as 40 against a row that laid out at 41, and every geometry test
/// in that file stayed green through it.
enum MiniIslandMetrics {
  /// The clock's `mm:ss` size. Half the cluster's 30pt, because this card is
  /// glanced at rather than read from across the desk — and the hour form still
  /// derives from it through `SessionTimerMetrics`, so crossing the hour costs
  /// no reflow here either.
  static let clockBase: CGFloat = 17

  /// The compact meter, the variant built for exactly this surface.
  static let meterVariant: SessionMeterMetrics.Variant = .compact

  /// The ember dot. Small: the meter beside it is the proof, and the dot is
  /// what makes the card legible as *recording* at a glance.
  static let dotDiameter: CGFloat = 8

  static let actionIconSize: CGFloat = 12
  static var actionMeasuringFont: NSFont { .systemFont(ofSize: actionIconSize, weight: .semibold) }
  /// The action capsules, sized to sit inside the card rather than to be the
  /// card — which is why the cluster's `RecordingCapsuleButtonStyle` (hard-framed
  /// to `RecordingPaneMetrics.capsuleHeight`) is not reused here.
  static let actionHeight: CGFloat = 26
  static let actionPaddingH: CGFloat = CraftTokens.spacing8

  static let contentGap: CGFloat = CraftTokens.spacing8
  static let paddingH: CGFloat = CraftTokens.spacing12
  static let paddingV: CGFloat = CraftTokens.spacing12

  static let messageFont: Font = .system(size: 12, weight: .medium)
  static var messageMeasuringFont: NSFont { .systemFont(ofSize: 12, weight: .medium) }

  /// The tallest thing the card has to hold. Measured, not chosen.
  static let contentHeight: CGFloat = {
    let glyph = ("0" as NSString).size(withAttributes: [.font: actionMeasuringFont]).height
    let message = ("0" as NSString).size(withAttributes: [.font: messageMeasuringFont]).height
    return max(
      SessionTimerMetrics.plateHeight(base: clockBase),
      meterVariant.maxBarHeight,
      dotDiameter,
      actionHeight,
      glyph.rounded(.up),
      message.rounded(.up)
    )
  }()

  static let cardHeight: CGFloat = contentHeight + 2 * paddingV

  /// **Constant**, in every phase. The card is up while the owner is looking at
  /// another app, so a surface that resized itself when a message arrived would
  /// be movement at the edge of vision for no information at all — and the
  /// stored position is a top-left, which is exact only because nothing grows.
  static let cardWidth: CGFloat = 320

  /// Transparent room where the card's shadow falls: a window cannot draw
  /// outside its own frame (`GlassBackingView`).
  static let shadowMargin: CGFloat = 24

  /// A capsule. `GlassBackingView` clamps to one anyway; saying it here is what
  /// makes the intent legible at the call site.
  static var cornerRadius: CGFloat { cardHeight / 2 }

  static var cardSize: CGSize { CGSize(width: cardWidth, height: cardHeight) }
  static var windowSize: CGSize {
    CGSize(width: cardWidth + 2 * shadowMargin, height: cardHeight + 2 * shadowMargin)
  }
}

// MARK: - What the panel is handed

/// One frame of the island: what to draw, and the feed the meter observes.
///
/// `level` is the session's own `MicLevelFeed`, passed as a reference rather
/// than as a `Float`, so the ~15 Hz feed is observed by `SessionMeterFeedView`
/// alone (XIA-432). Nothing above that leaf may hold it as observed state.
@MainActor
struct MiniIslandRender {
  var phase: MiniIslandPhase
  var elapsed: TimeInterval
  var level: MicLevelFeed?

  init(phase: MiniIslandPhase, elapsed: TimeInterval = 0, level: MicLevelFeed? = nil) {
    self.phase = phase
    self.elapsed = elapsed
    self.level = level
  }
}

/// The island's view model. Published so the panel's hosting view re-renders on
/// a phase or a second, and **only** on those: the microphone's own feed is a
/// plain reference handed straight to the meter's leaf.
@MainActor
final class MiniIslandModel: ObservableObject {
  @Published var phase: MiniIslandPhase = .recording
  @Published var elapsed: TimeInterval = 0
  /// Assigning the reference publishes once; its contents never do, here.
  @Published var level: MicLevelFeed?

  var perform: (MiniIslandAction) -> Void = { _ in }
  var onDragChanged: () -> Void = {}
  var onDragEnded: () -> Void = {}

  func apply(_ render: MiniIslandRender) {
    if phase != render.phase { phase = render.phase }
    if elapsed != render.elapsed { elapsed = render.elapsed }
    if level !== render.level { level = render.level }
  }
}

// MARK: - The card

/// The island as drawn. One row, one size, four phases.
struct MiniRecorderIslandView: View {
  @ObservedObject var model: MiniIslandModel

  var body: some View {
    HStack(spacing: MiniIslandMetrics.contentGap) {
      leading
      Spacer(minLength: 0)
      trailing
    }
    .padding(.horizontal, MiniIslandMetrics.paddingH)
    .frame(width: MiniIslandMetrics.cardWidth, height: MiniIslandMetrics.cardHeight)
    // Dark in both system themes, matching the panel's own
    // `NSAppearance(named: .darkAqua)`. Neither alone is enough: this one
    // reaches SwiftUI, that one reaches everything AppKit draws inside.
    .colorScheme(.dark)
    // **The handle is the CARD, not the window.** `.contentShape` goes inside
    // the shadow margin deliberately, and the difference is not cosmetic: the
    // review card claims its margin because that card is a surface the owner is
    // working *in*, while this one hovers over the app they are working in — a
    // press 20pt off its visible edge landing on an invisible drag handle is a
    // click that silently did nothing. (The margin is still the panel's frame,
    // so such a click does not reach the app underneath either; what it can no
    // longer do is move the island. Making it pass through would take a
    // per-region window, which AppKit has no such thing as.)
    .contentShape(Rectangle())
    // What the margin is actually for. `hasShadow` is false on the panel — a
    // window shadow can only draw inside the frame, which turns it into a dark
    // rectangle behind a capsule — so the card casts its own, into the room
    // reserved for it.
    .shadow(color: .black.opacity(0.32), radius: 10, y: 3)
    .padding(MiniIslandMetrics.shadowMargin)
    // The whole card is the handle, except the buttons — SwiftUI buttons take
    // precedence over a container gesture, which is what makes this safe. The
    // drag is measured by the panel against `NSEvent.mouseLocation`; this
    // gesture only says when.
    .gesture(
      DragGesture(minimumDistance: 2)
        .onChanged { _ in model.onDragChanged() }
        .onEnded { _ in model.onDragEnded() }
    )
  }

  @ViewBuilder
  private var leading: some View {
    if model.phase.showsEmber {
      emberDot
      if let level = model.level {
        SessionMeterFeedView(feed: level, variant: MiniIslandMetrics.meterVariant)
      }
    } else {
      Image(systemName: statusGlyph)
        .font(.system(size: MiniIslandMetrics.actionIconSize, weight: .semibold))
        .foregroundStyle(.white.opacity(0.8))
    }

    if model.phase.showsClock {
      SessionTimer(elapsed: model.elapsed, base: MiniIslandMetrics.clockBase)
    }

    if let message = model.phase.message {
      Text(message)
        .font(MiniIslandMetrics.messageFont)
        .foregroundStyle(.white.opacity(0.92))
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  private var trailing: some View {
    HStack(spacing: CraftTokens.spacing4) {
      ForEach(model.phase.actions, id: \.self) { action in
        Button {
          model.perform(action)
        } label: {
          Image(systemName: action.symbol)
        }
        .buttonStyle(IslandActionButtonStyle(tint: action.tint))
        // No `.keyboardShortcut` here on purpose — see `MiniIslandAction
        // .shortcut`. This panel never becomes key, so one would never fire.
        .accessibilityLabel(action.label)
        .help(action.help)
      }
    }
  }

  private var emberDot: some View {
    Circle()
      .fill(CraftTokens.ember(.dark))
      .frame(width: MiniIslandMetrics.dotDiameter, height: MiniIslandMetrics.dotDiameter)
      .accessibilityLabel(RecordingPaneCopy.listening)
  }

  private var statusGlyph: String {
    if case .failure = model.phase { return "exclamationmark.triangle.fill" }
    return "waveform"
  }
}

/// The island's action capsule. Its own style rather than the cluster's, for
/// one reason: `RecordingCapsuleButtonStyle` is hard-framed to
/// `RecordingPaneMetrics.capsuleHeight`, which is taller than this whole card.
/// The vocabulary is the same — a tinted fill drawn **over** the glass, so
/// Reduce Transparency takes the material and not the colour (Stop may never go
/// grey).
struct IslandActionButtonStyle: ButtonStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: MiniIslandMetrics.actionIconSize, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, MiniIslandMetrics.actionPaddingH)
      .frame(minWidth: MiniIslandMetrics.actionHeight)
      .frame(height: MiniIslandMetrics.actionHeight)
      .background(RecordingCapsuleTint.fill(tint), in: Capsule(style: .continuous))
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}
