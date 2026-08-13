import AppKit
import SwiftUI

// MARK: - Metrics

/// Everything about the recording surface that is arithmetic, kept out of the
/// views for the reason `SessionTimerMetrics` and `HUDPrompterMetrics` are: a
/// test can then answer "how tall is a capsule" without a window server.
enum RecordingPaneMetrics {
  // MARK: The capsule cluster

  /// Three sibling capsules — timer, Mark, Stop — floating over the transcript
  /// at the bottom of the window (XIA-445). They replaced the full-width bar
  /// XIA-444 shipped, which had replaced a 288pt trailing column.
  ///
  /// The bar was measured and rejected: it still charged the transcript a whole
  /// band of every window for an indicator that is a clock, a meter and two
  /// buttons wide, and it grew that band on hover. A cluster charges the
  /// transcript nothing at all — it floats over it — and the transcript reserves
  /// exactly the cluster's footprint at the bottom so no line ever comes to rest
  /// under glass (`transcriptBottomReserve`).
  ///
  /// They are **siblings**, never nested. Apple's guidance is that Liquid Glass
  /// inside Liquid Glass is silently auto-converted to a vibrant fill, so a
  /// capsule drawn inside a capsule is not doubled — it is quietly overridden,
  /// which is a failure nothing on screen announces. One `GlassEffectContainer`
  /// holds the three so their lensing merges rather than refracting three times.
  ///
  /// It is a SwiftUI `.glassEffect` here, via `craftGlassPanel`, and that is not
  /// a contradiction of the HUD's rule. That rule is about an `NSPanel`: SwiftUI
  /// glass refracts only its own hierarchy, and a floating panel's hierarchy is
  /// a glyph and a line of text. This cluster is inside the main window, and the
  /// field it refracts *is* in its hierarchy.

  /// The clock's `mm:ss` size. One size, because the cluster has one state —
  /// the bar's hover bloom (22pt → 58pt) is gone with the bar, and with it the
  /// hover machinery, the two reserved plates and the animation between them.
  /// `SessionTimerMetrics` derives the hour form from this and reserves the
  /// wider of the two, so crossing the hour still costs no reflow (XIA-431).
  static let clockBase: CGFloat = 30

  /// Above and below whatever the capsule holds. Small on purpose: the clock's
  /// own line box is what gives the capsule its height, and padding on top of a
  /// 30pt plate is what turns it into a control rather than a card.
  static let capsulePaddingV: CGFloat = CraftTokens.spacing4
  static let timerPaddingH: CGFloat = CraftTokens.spacing16
  /// Between the meter and the clock inside the timer capsule.
  static let timerContentGap: CGFloat = CraftTokens.spacing12
  /// Inside an action capsule, past its square minimum — what the moment count
  /// gets to spend when it appears beside the flag.
  static let actionPaddingH: CGFloat = CraftTokens.spacing12
  /// Between two capsules, and the merge distance the container is given: the
  /// same number in both places or the glass merges at a gap the eye does not
  /// see, or fails to merge at the one it does.
  static let capsuleGap: CGFloat = CraftTokens.spacing8
  /// The cluster's own clearance from the bottom of the pane.
  static let clusterBottomInset: CGFloat = CraftTokens.spacing24
  /// Between the cluster's top edge and the last line the transcript may draw.
  ///
  /// Back to a plain `spacing16` (owner, 2026-08-12). It was briefly the larger
  /// of this and the paused badge's lifted height, because that badge was an
  /// overlay drawn ≈31pt above the row and landed on the last lines of the live
  /// transcript. The word is on the Pause capsule now, so nothing is drawn
  /// above the row and the transcript gets that space back.
  static let clusterTranscriptGap: CGFloat = CraftTokens.spacing16

  /// The meter in the cluster. `.compact`, and named rather than passed at the
  /// call site because `capsuleContentHeight` has to measure the same one the
  /// capsule draws.
  static let meterVariant: SessionMeterMetrics.Variant = .compact

  /// The action capsules' symbol size, and the AppKit twin of the face that
  /// draws it — `capsuleContentHeight` measures the icon's line box from this,
  /// so a bigger glyph cannot outgrow the row that was reserved for it.
  static let actionIconSize: CGFloat = 15
  static var actionMeasuringFont: NSFont { .systemFont(ofSize: actionIconSize, weight: .semibold) }

  /// The plate the moment tally is drawn on: two digits wide, reserved up
  /// front — and reserved **from zero**, drawn empty until there is a tally.
  ///
  /// The zero→one step was the half this constant did not cover and the half
  /// that shipped broken. `RecordingPaneCopy.markerCount` returns nil at zero
  /// so the surface never says "0", and the first cut drew *nothing at all*
  /// there — so the plate and its `spacing4` appeared out of nothing on the
  /// first ⌘K, and since the cluster is centred that widening split across both
  /// sides and stepped Stop ~11pt right, out from under the pointer resting on
  /// it. Master's full-width bar was immune by accident: a `Spacer(minLength:)`
  /// pinned the trailing edge, so the widening was absorbed leftward. A centred
  /// cluster has no such spacer and has to reserve instead.
  ///
  /// One→two **digits** is the same defect at the tenth moment, and it moves
  /// the same control.
  ///
  /// Reserving a plate wide enough for both answered it and cost the row its
  /// shape: the plate is drawn from zero, so Mark carried it permanently empty
  /// and laid out at 44pt against Stop's 23pt. The count is a **badge overlay**
  /// now (`SessionCapsuleCluster.markerCount`), which is outside the layout
  /// entirely — so no count of any width can move Stop, and there is nothing
  /// left to reserve. These three numbers are the badge's own, and none of them
  /// reaches the row: `capsuleHeight`, `transcriptBottomReserve` and every
  /// cluster width are computed without them.
  static let markerBadgeFontSize: CGFloat = 11
  static let markerBadgePaddingH: CGFloat = CraftTokens.spacing4
  /// A two-digit tally is wider than this and grows past it; one digit is
  /// round, which is what a badge should be at its most common value.
  static let markerBadgeDiameter: CGFloat = 18
  /// Half the badge, so it straddles the capsule's rim rather than sitting
  /// inside it (where the glyph is) or beside it (where nothing is).
  static let markerBadgeInset: CGFloat = 6

  /// **The Pause capsule says the word itself** (owner, 2026-08-12: "instead of
  /// adding a pill on top of the control, the pause button becomes ▶ Paused").
  ///
  /// It replaced a badge floating above the row, and it is the better answer
  /// for a reason worth keeping: the control that will resume the session is
  /// the one telling the owner it is paused, so the state and the way out of it
  /// are the same object. The badge said the word *near* the row and could be
  /// read as belonging to any capsule in it.
  ///
  /// **The capsule grows, and the row gives way** (owner, 2026-08-13, on
  /// seeing the reserved form: "when not pause, same as before, when pause,
  /// pill grows, pushes the neighbors to either direction"). The first cut
  /// reserved the wide form up front — `SessionTimerMetrics.plateWidth`'s
  /// trick, which is what keeps the hour from moving Stop — and it kept that
  /// rule at a cost the owner saw immediately: a round blue glyph floating in
  /// the middle of an invisible box wide enough for a word it was not saying,
  /// so the three gaps in a row of four capsules read as three different gaps.
  /// That is the `markerCountWidth` lesson a second time: a reservation the
  /// eye can measure is worse than the movement it prevents.
  ///
  /// So Pause is sized by its content in both states, and the widening is the
  /// point rather than the cost — a capsule that visibly grows into the word is
  /// the state change, and the centred row splits the growth evenly so both
  /// neighbours slide rather than one. What the reservation protected is still
  /// protected where it matters: **Stop is not the capsule that moves under a
  /// press of Pause**, because the pointer that widened the row is on Pause.
  /// The rule that survives untouched is the tally's — a moment count may never
  /// move anything, which is why it is still an overlay.
  static let pausedTitleGap: CGFloat = CraftTokens.spacing8
  /// The face the word is drawn in, and its AppKit twin for measuring. Smaller
  /// than the glyph: it is a state, not a second label competing with it.
  static let pausedTitleFontSize: CGFloat = 12
  static var pausedTitleMeasuringFont: NSFont {
    .systemFont(ofSize: pausedTitleFontSize, weight: .semibold)
  }

  /// The tallest thing any capsule has to hold. **Measured, not typed** — this
  /// is the precedent XIA-444 got wrong: `controlRowHeight` was written as 40
  /// against a row that laid out at 41, so the bar promised 64 and drew 65, the
  /// `.frame(minHeight:)` never bound, and every geometry test in the file
  /// stayed green through it. A number that calls itself a derivation has to
  /// *be* one, and to be compared against the laid-out view.
  ///
  /// `static let` because it builds two `NSFont`s and measures two strings, and
  /// the cluster's body re-runs on every tick of the clock.
  static let capsuleContentHeight: CGFloat = {
    let icon = ("0" as NSString)
      .size(withAttributes: [.font: actionMeasuringFont])
      .height
    return max(
      SessionTimerMetrics.plateHeight(base: clockBase),
      meterVariant.maxBarHeight,
      icon.rounded(.up)
    )
  }()

  /// **One height for all three.** A row of capsules is one object made of
  /// parts; three heights reads as three things that happen to be near each
  /// other. Every capsule takes this as a hard frame, which is safe only
  /// because it was derived from the tallest content rather than chosen.
  static let capsuleHeight: CGFloat = capsuleContentHeight + 2 * capsulePaddingV

  /// What the transcript owes the cluster: the whole footprint, so no line can
  /// come to rest behind glass (owner's call, 2026-08-11 — "Reserve space",
  /// over reading through the refraction or having the cluster fade while text
  /// arrives). Computed from the constants the cluster is *placed* with, never
  /// typed a second time, or the reserve and the placement drift apart.
  static let transcriptBottomReserve: CGFloat =
    capsuleHeight + clusterBottomInset + clusterTranscriptGap

  // MARK: The transcript

  /// The timestamp gutter, mirroring the rich document pane so a live
  /// transcript and a finished one are read the same way.
  static let gutterWidth: CGFloat = 52
  static let gutterGap: CGFloat = CraftTokens.spacing12
  static let transcriptPaddingH: CGFloat = CraftTokens.spacing24
  static let transcriptPaddingV: CGFloat = CraftTokens.spacing24
  /// Between two blocks. Larger than between two lines *inside* one block —
  /// that difference is what makes a per-speaker block read as a turn.
  static let blockSpacing: CGFloat = CraftTokens.spacing16
  static let lineSpacing: CGFloat = CraftTokens.spacing4

  // MARK: The marker rule (XIA-433)

  /// The ember rule beside a marked line. Two points: it is a *rule*, not a
  /// bar — the one thing on the reading surface allowed to be warm, and the
  /// least of it that can still be seen.
  static let markerRuleWidth: CGFloat = 2
  /// How far into the left margin the rule sits, measured from the row's own
  /// leading edge. **Derived**, not typed: half the transcript's horizontal
  /// padding, so the rule is centred in the margin the transcript already has
  /// and can never be pushed off the window by a padding change. It is drawn
  /// as an overlay, so this is an offset and not an inset — no text moves.
  static var markerRuleInset: CGFloat { transcriptPaddingH / 2 }

  // MARK: Type

  static let kindLineFont: Font = .system(size: 13, weight: .medium)
  static let markerTimeFont: Font = CraftTokens.metadataFont
  static let markerLabelFont: Font = .system(size: 12)
  static let speakerFont: Font = .system(size: 12, weight: .semibold)
  static let transcriptFont: Font = .system(size: 14)
  static let gutterFont: Font = .system(size: 11, weight: .regular, design: .monospaced)

  // There is no `volatileOpacity` here any more. The tail was dimmed to 55% to
  // match the HUD prompter — a number off the tier table, one point under
  // `GroundInk.Tier.timestamp`'s 56%. It was **not** below the readability
  // floor: the solve says 3.0:1 wants 54% light and 40% dark, so 55% cleared it
  // on both themes. What it was, was unmeasured — an alpha nobody swept, sitting
  // between two that were. So the transcript draws the tail at the tier instead,
  // and every alpha the transcript spends is one the sweep solved. The HUD keeps
  // its own 55%: that is white text on a dark glass plate, not ink on the field,
  // and it was never in this measurement — nothing here is a finding against it.
}

// MARK: - Capsule tint

/// How strongly an action capsule is coloured, and the one place that number
/// lives.
///
/// The tint is drawn as the capsule's own background **over** its glass rather
/// than through `Glass.tint(_:)`, and the difference is Reduce Transparency:
/// the degraded branch of `liquidGlass` swaps the effect for `.regularMaterial`
/// and a `Glass` tint goes with it. Stop is the one control that may never be
/// hard to find, so its colour may not be a property of a material the system
/// is allowed to take away. Both action capsules use the same mechanism — one
/// vocabulary, and Mark is not worth a second one.
///
/// 62% is the owner's, chosen against the live prototype on 2026-08-11: enough
/// that the capsule reads as its colour over any ground, little enough that the
/// glass under it still refracts rather than being a flat button.
enum RecordingCapsuleTint {
  static let strength: Double = 0.62

  static func fill(_ tint: Color) -> Color { tint.opacity(strength) }
}

// MARK: - The meter's feed

/// When the microphone's level may be republished.
///
/// `MicCapture` installs its tap with a 1024-frame buffer at the source rate —
/// a delivery roughly every 21 ms, ~45 a second. An unconditional assignment to
/// a `@Published` property fires `objectWillChange` on every one of them, and
/// the meter's first home was `LiveMeetingSession`, which `ContentView` and
/// `LiveMeetingView` both observe: each tick invalidated the whole window body,
/// toolbar and transcript included. CLAUDE.md already records this trap for the
/// HUD prompter ("re-rendered on every 66 ms RMS tick … an unbounded main-actor
/// cost on a feed that ticks 15 times a second"); this was three times that
/// rate against a much larger hierarchy.
///
/// So the level lives on its own object (`MicLevelFeed`) that only the meter
/// observes, **and** the writes are gated. Two gates, because either alone
/// leaves a hole:
///
/// - **Time.** Never faster than `minInterval` — the HUD's own tick, and more
///   than a bar can visibly move between.
/// - **Movement.** A change smaller than `minDelta` is a change nobody can see;
///   spending a render on it is spending it on nothing.
///
/// And one escape, because the movement gate alone can wedge: a level that
/// decays toward silence in steps below the threshold would never publish
/// again, leaving a full meter over a quiet room — which is the exact lie the
/// meter exists to make impossible. After `maxHold` any difference at all
/// publishes.
enum MeterPublishGate {
  /// 66 ms — the HUD's RMS tick, i.e. ~15 Hz.
  static let minInterval: TimeInterval = 0.066
  /// Below this the tallest bar moves under a point.
  static let minDelta: Float = 0.02
  /// Past this, any difference publishes: convergence beats economy.
  static let maxHold: TimeInterval = 0.5

  static func shouldPublish(
    new: Float,
    last: Float,
    now: TimeInterval,
    lastPublishedAt: TimeInterval
  ) -> Bool {
    guard new != last else { return false }
    let since = now - lastPublishedAt
    guard since >= minInterval else { return false }
    return abs(new - last) >= minDelta || since >= maxHold
  }
}

/// The microphone level, published on an object **only the meter observes**.
///
/// It is deliberately not a `@Published` property of `LiveMeetingSession`: that
/// object is observed by `ContentView` and `LiveMeetingView`, and a 45 Hz feed
/// on it re-renders the window. Held by the session as a plain `let`, so
/// mutating it never touches the session's own `objectWillChange`.
@MainActor
final class MicLevelFeed: ObservableObject {
  @Published private(set) var level: Float

  private var lastPublishedAt: TimeInterval = -.greatestFiniteMagnitude

  init(level: Float = 0) {
    self.level = level
  }

  /// Publish if `MeterPublishGate` allows it. `now` is injected so the gate is
  /// testable without waiting out a real 66 ms.
  func publish(_ level: Float, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard
      MeterPublishGate.shouldPublish(
        new: level,
        last: self.level,
        now: now,
        lastPublishedAt: lastPublishedAt
      )
    else { return }
    self.level = level
    lastPublishedAt = now
  }

  /// Silence, immediately and ungated. Capture ending is the one level change
  /// that may not wait for a tick: a meter frozen at the last thing it heard is
  /// a meter claiming a live session.
  func silence(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    guard level != 0 else { return }
    level = 0
    lastPublishedAt = now
  }
}

/// `SessionMeter` bound to the live feed.
///
/// This wrapper is the entire point of the split: `@ObservedObject` **here**
/// means a level tick re-runs *this* body and nothing above it — not the
/// column, not the transcript, not the window.
struct SessionMeterFeedView: View {
  @ObservedObject var feed: MicLevelFeed
  var variant: SessionMeterMetrics.Variant
  /// Passed straight through to `SessionMeter.isLive` (XIA-447): the level
  /// falls to zero at a pause, and the meter's *floor* is drawn at zero, so
  /// without this the paused cluster kept ember bars over a closed microphone.
  var isLive: Bool = true

  var body: some View {
    SessionMeter(level: feed.level, variant: variant, isLive: isLive)
  }
}

// MARK: - Copy

/// Every fixed string the recording surface draws, in one place.
///
/// It is a type rather than string literals scattered through the views because
/// of the promise it exists to keep: **a memo and a meeting differ by exactly
/// one word**. The accent does not change, no chrome changes, no control
/// changes — the kind is a label and it is relabelable after the fact
/// (`docs/design/recording-refresh-inspiration.md`, don't #6). `all(kind:…)`
/// is what a test can diff to hold that.
enum RecordingPaneCopy {
  /// "Meeting" / "Memo" — the whole of the difference.
  static func noun(_ kind: HistoryKind) -> String {
    kind == .memo ? "Memo" : "Meeting"
  }

  /// What the session is doing, independent of the kind.
  static func activity(_ controls: LiveMeetingControls) -> String {
    switch controls {
    case .start: return "ready"
    case .starting: return "starting"
    case .stop: return "listening"
    case .paused: return "paused"
    case .finalizing: return "finishing"
    case .saveOrDiscard, .retryOrDiscard: return "stopped"
    }
  }

  /// The kind line: "Meeting · listening".
  ///
  /// Since XIA-445 it reaches the screen in the **idle** state alone. The
  /// cluster draws no kind: the owner chose the "C · Essential" timer capsule,
  /// which is the meter and the clock and nothing else, on the reasoning that a
  /// kind is relabelable after Stop and forbidden from changing anything visual
  /// — so during a session it is a word that never moves and never does
  /// anything. It stays in `all(kind:controls:)` because it is still the whole
  /// of the difference between a memo and a meeting, and that promise is about
  /// the pane rather than about one of its states.
  static func kindLine(kind: HistoryKind, controls: LiveMeetingControls) -> String {
    "\(noun(kind)) · \(activity(controls))"
  }

  /// What a marker row says beside its timestamp — **nothing**, until XIA-433
  /// gives markers a meaning to say. It used to fall back to the section
  /// heading, so every row under a heading reading MOMENTS read `12:04 Moments`:
  /// drawn, and evidently never looked at. A timestamp alone is the honest row,
  /// and it is the row the auto-titled label will land in.
  static func markerLabel(_ marker: SessionMarker) -> String? {
    marker.label
  }

  /// Both action capsules are **icon only** on the cluster (owner, 2026-08-11),
  /// so these reach the owner as the accessibility label and the tooltip rather
  /// than as a drawn label — which is exactly why they are strings the surface
  /// puts in front of someone, and why they are in `all(kind:controls:)`.
  /// `SessionClusterAction` is where each capsule picks the one it wears.
  static let markTitle = "Mark"
  static let markShortcut = "⌘K"
  /// The Mark capsule's tooltip. Icon-only means the shortcut has exactly one
  /// place left to be named, so it is named there rather than nowhere.
  static var markHelp: String { "\(markTitle) \(markShortcut)" }
  static let stopTitle = "Stop"
  static let listening = "Listening…"

  /// The pause capsule's two faces (XIA-447). One capsule, one job — stop
  /// capturing without ending the session, and start again — so it is one case
  /// in the table with a face that depends on whether the session is paused,
  /// rather than two cases only one of which is ever drawable.
  static let pauseTitle = "Pause"
  static let resumeTitle = "Resume"

  /// **The literal word, on the cluster.** A paused session may never look
  /// stopped — the owner walks away, comes back to a quiet screen, assumes it
  /// ended, and loses the meeting. The ember going out and the clock stopping
  /// are both *absences*, and an absence is exactly what a stopped session
  /// looks like, so the state has to say its own name. The island and the menu
  /// bar say the same word, through `LiveMeetingFormat.stateLabel`.
  static let pausedTitle = "Paused"

  /// Shown over the transcript when a ⌘K did not reach the record (XIA-433).
  ///
  /// The tally on the Mark capsule is the whole of what a press says out loud,
  /// so an unwritable record — a full disk, a store on a network mount that
  /// dropped, a record deleted from a terminal mid-session — would otherwise
  /// have the count climbing over a file that holds none of it. It names what
  /// is still true (the moments are in this session) and what is not (they are
  /// not on disk yet), and it goes away by itself: every press writes the whole
  /// list, so the next one that lands carries the ones that did not.
  static let markersUnsaved = "Moments aren't reaching this recording yet — kept for now."

  /// `SessionMarkerList`'s two strings. They are **not** in
  /// `all(kind:controls:)` any more: that list is every string the surface can
  /// put on screen, and since the Moments capsule went there is no surface that
  /// draws these. They survive with the view they belong to, for XIA-433.
  static let markersHeading = "Moments"
  static let noMarkers = "No moments yet"

  /// The count on the Mark capsule — **nil at zero**, not "0".
  ///
  /// The button itself is always there, and since the zero→one fix so is the
  /// *plate* it is drawn on (`SessionCapsuleCluster.markerCount`): an
  /// affordance — or a reservation — that appeared the moment the first moment
  /// was flagged would be a control that moves under the pointer, on the one
  /// surface whose whole job is to hold still. What it may not do is report a
  /// tally nobody has started, so an empty log shows the glyph alone.
  ///
  /// Not part of `all(kind:controls:)` below, and that is deliberate: this is
  /// the one string on the surface that is a function of the session rather
  /// than of the (kind, controls) pair, so it cannot differ between a memo and
  /// a meeting no matter what it says.
  static func markerCount(_ markers: [SessionMarker]) -> String? {
    markers.isEmpty ? nil : "\(markers.count)"
  }

  /// Every string the pane can put on screen for one (kind, controls) pair.
  /// The test that diffs meeting against memo reads this, so a string added to
  /// a view without being added here is a string the promise stops covering —
  /// which is exactly the drift worth failing on.
  static func all(kind: HistoryKind, controls: LiveMeetingControls) -> [String] {
    [
      kindLine(kind: kind, controls: controls),
      markTitle,
      markShortcut,
      markHelp,
      pauseTitle,
      resumeTitle,
      pausedTitle,
      stopTitle,
      listening,
      markersUnsaved,
    ]
  }
}

// MARK: - Moment markers

/// A flagged moment in a running session.
///
/// `label` is unused today and deliberately present: the marker's *meaning*
/// (auto-titled from the surrounding transcript) is a follow-up, and a row that
/// has to grow a second line later is a row that has to be re-laid-out later.
///
/// Two times, because they answer different questions and neither can be
/// derived from the other. `at` is where the mark lands **in the recording** —
/// the only one the transcript, the summary or a future scrubber can use — and
/// `createdAt` is the wall clock, which is what survives the record being read
/// by something that never had the session's origin. Both are persisted
/// (`LiveSessionPersistence.markerDictionaries`), which is why `createdAt` is
/// a stored property rather than stamped at write time: a marker written at
/// press time and rewritten on the next press must not change its own history.
struct SessionMarker: Equatable, Identifiable {
  let id: UUID
  /// Seconds into the session.
  let at: TimeInterval
  /// Wall clock at the moment the owner pressed.
  let createdAt: Date
  var label: String?

  init(id: UUID = UUID(), at: TimeInterval, createdAt: Date = Date(), label: String? = nil) {
    self.id = id
    self.at = at
    self.createdAt = createdAt
    self.label = label
  }
}

/// The marker list's ordering rule, pure so "newest first" is a fact rather
/// than an argument about where `append` was called.
enum SessionMarkerOrder {
  /// Newest first — the list sits at the bottom of the column, and the moment
  /// the owner just flagged is the one they are looking for.
  static func inserting(_ marker: SessionMarker, into markers: [SessionMarker]) -> [SessionMarker] {
    [marker] + markers
  }
}

/// The session's marker list, in memory.
///
/// It is the *view's* copy and it is no longer the only one (XIA-433): every
/// press also writes the whole list onto the history record, at press time, so
/// a session that never reaches Stop keeps its moments. That write is the
/// model's — this type owns no disk and no record id, which is what keeps the
/// ordering rule and the clamp assertable without a store.
///
/// Nothing *lists* these while a session runs — the recording surface has no
/// marker list (owner, 2026-08-11; see `SessionCapsuleCluster`) — so the count
/// on the Mark capsule is what a mark says out loud in-window. The ember rule
/// in the transcript's margin (XIA-433, item 3, asked for by name) is not a
/// second readback and does not reopen that call: it names *where* a moment
/// landed among the words that were being said, it lists nothing, it cannot be
/// opened or scrolled to, and it exists only while the microphone is open.
@MainActor
final class SessionMarkerLog: ObservableObject {
  @Published private(set) var markers: [SessionMarker] = []

  /// `createdAt` is a parameter so a test can pin the wall clock; production
  /// never passes one. Returns the marker it inserted, so a caller with
  /// something to say about *this* press has it in hand.
  ///
  /// A non-finite `elapsed` is clamped to zero rather than stored. `max(0, x)`
  /// already answers 0 for NaN (`nan >= 0` is false) and does **not** for
  /// `+infinity` — and an infinity reaching the record would not cost one bad
  /// marker: the whole array is written on every press and `JSONSerialization`
  /// refuses a non-finite Double, so a single such value vetoes every moment of
  /// the session, including the ones already safely on disk, for the rest of
  /// the session.
  @discardableResult
  func mark(at elapsed: TimeInterval, createdAt: Date = Date()) -> SessionMarker {
    let marker = SessionMarker(
      at: elapsed.isFinite ? max(0, elapsed) : 0,
      createdAt: createdAt
    )
    markers = SessionMarkerOrder.inserting(marker, into: markers)
    return marker
  }

  func reset() {
    markers = []
  }
}

/// What ⌘K and the Mark capsule do, as one function a test can drive.
///
/// The view's `mark()` is the one call site of the whole feature and it is a
/// SwiftUI view method, which no test in this bundle can reach. So the press
/// itself lives here: the log moves, the record is written **at press time**
/// with the whole list, and the answer to that write is **returned rather than
/// dropped** — a moment the owner believes they flagged and the record does not
/// hold is the failure this ticket exists to remove, and the tally on the Mark
/// capsule is the only feedback a press has.
///
/// **A failed write does not throw the moment away.** It stays in the log, and
/// because every press rewrites the whole array the next successful press
/// carries it — one transient failure heals itself instead of costing the owner
/// a moment they cannot recreate. What the surface owes in the meantime is to
/// stop claiming success, which is what the false is for
/// (`RecordingPaneCopy.markersUnsaved`, drawn over the transcript until a press
/// lands).
@MainActor
enum SessionMarkPress {
  /// Returns whether the moment reached the record.
  static func press(
    log: SessionMarkerLog,
    at elapsed: TimeInterval,
    now: Date = Date(),
    write: ([SessionMarker]) -> Bool
  ) -> Bool {
    log.mark(at: elapsed, createdAt: now)
    return write(log.markers)
  }
}

/// Which transcript line a marker belongs to.
///
/// **The rule: a marker at `t` belongs to the first line whose `endTime >= t`**
/// — the turn that was in flight when the owner pressed. A `LiveSegment`
/// carries only an end time and the codebase's standing idiom is that a
/// segment's start is the previous segment's end (`segmentDictionaries`,
/// `buildMarkdown`), so that predicate *is* `start <= t < end` with the starts
/// derived, and it needs no field the pipeline does not fill.
///
/// Two properties it is chosen for, both of which the obvious alternative
/// ("the nearest line") loses:
///
/// - **It never moves a rule that has already been drawn.** Lines are appended
///   with ascending end times, so a line that already covers `t` keeps
///   covering it forever. The volatile tail (`endTime == elapsed`) covers every
///   fresh mark, and when that tail finalizes into a segment of about the same
///   end time the rule lands on the same words.
/// - **A mark past every line simply has no line yet**, rather than being
///   attached to the last one and jumping forward when the next turn arrives.
///   Marking during silence is exactly the case, and a rule that relocates
///   itself under the owner's eyes is worse than a rule that arrives with the
///   words it belongs to. The mark is not lost by that: it is on disk and in
///   the tally the instant it is pressed, which is what item 4 of the ticket
///   asks for — a marker is a timestamp, not an annotation on text.
///
/// **It is one pass, not a scan per marker.** Both inputs are ordered — lines
/// by construction (segments arrive with ascending end times and the volatile
/// tail closes them), markers by the sort here — so the matching walks each
/// list once. `first(where:)` per marker is O(markers × lines), and it runs
/// inside the row model, which is rebuilt on every volatile recognizer result:
/// a 90-minute meeting with 800 lines and 40 marks would have spent ~16,000
/// comparisons ~15 times a second on the main actor, which is the XIA-432 trap
/// arriving on the one tick the row cache does not refuse.
enum LiveTranscriptMarking {
  static func markedLineIDs(
    markers: [SessionMarker],
    lines: [LiveTranscriptLine]
  ) -> Set<UUID> {
    guard !markers.isEmpty, !lines.isEmpty else { return [] }
    var ids: Set<UUID> = []
    var index = lines.startIndex
    // Ascending, whatever order the log holds them in — the log is newest
    // first, and a single forward walk needs the marks in the order the lines
    // are in.
    for at in markers.map(\.at).sorted() {
      while index < lines.endIndex, lines[index].endTime < at { index += 1 }
      // Past the last line: this mark has no line yet, and neither has any
      // later one, so the walk is over.
      guard index < lines.endIndex else { break }
      ids.insert(lines[index].id)
    }
    return ids
  }
}

// MARK: - Transcript model

/// One line of live transcript as the pane needs to draw it.
///
/// `speaker` is the field the realtime pipeline does not fill yet — AssemblyAI
/// realtime speaker labels are a known unresolved follow-up. It is here anyway,
/// and the grouping below already honours it, because the reference sweep's
/// note was explicit (do #6): leave room for a speaker column *before* the
/// labels exist, so the day they arrive the transcript gains names and loses
/// no layout.
struct LiveTranscriptLine: Equatable, Identifiable {
  let id: UUID
  let text: String
  let endTime: TimeInterval
  var speaker: String?
  /// The in-flight recognition tail: drawn dimmed, replaced wholesale on the
  /// next update, and never part of what has been said.
  var isVolatile: Bool = false
}

/// Consecutive lines from one speaker, drawn as a turn with the name above it.
struct LiveTranscriptBlock: Equatable, Identifiable {
  /// The first line's id, so a block is a stable scroll anchor across the
  /// updates that extend it.
  let id: UUID
  let speaker: String?
  /// The block's own gutter timestamp — where the turn *started*.
  let startedAt: TimeInterval
  var lines: [LiveTranscriptLine]
}

/// One **drawn** row of the live transcript.
///
/// Rows are flat on purpose, and that is a correction rather than a style. A
/// `LazyVStack` defers only its **direct** children; the first cut put each
/// block in the stack and each block's lines in an inner `VStack`, and since
/// `speaker` is nil for every line the pipeline produces today, the entire
/// session was one block — one child — so every `Text` the meeting had ever
/// drawn was built and measured on every render pass, on screen or not. Master
/// put each segment directly in the stack and only built what was visible.
///
/// Flattening keeps that laziness and keeps the grouping: the speaker name a
/// block used to draw above its lines is emitted as its own row where the
/// speaker changes, which is the same picture with one less level of nesting.
struct LiveTranscriptRow: Equatable, Identifiable {
  enum Content: Equatable {
    /// A turn's speaker name. Emitted only where the speaker changes, so it is
    /// absent entirely until the realtime pipeline fills the labels in.
    case speaker(String)
    case line(LiveTranscriptLine)
  }

  /// Typed, because a speaker row and its turn's first line would otherwise
  /// share an id — a block anchors on its first line.
  enum ID: Hashable {
    case speaker(UUID)
    case line(UUID)
  }

  let id: ID
  /// The gutter timestamp, present only on the row that **starts** a turn. A
  /// continuation row still reserves the cell and draws nothing in it, or its
  /// text would step left under the line above it.
  let gutter: TimeInterval?
  let content: Content
  /// A moment was flagged during this line, so it wears the ember rule in the
  /// left margin (XIA-433). A flag on the row rather than a wrapper around a
  /// run of rows, for the reason the whole model is flat: anything that groups
  /// rows into a container collapses the `LazyVStack` back into one child.
  /// It is drawn as an **overlay**, so no marked line is a different size from
  /// an unmarked one and no text moves when a mark lands.
  var isMarked: Bool = false

  /// Rows that start a turn take the larger inter-block gap. That difference is
  /// what makes a turn read as a turn once a flat stack has no blocks left to
  /// space apart.
  var startsTurn: Bool { gutter != nil }
}

enum LiveTranscript {
  /// One stable id for the volatile tail, so the scroll reader can chase a run
  /// that is rewritten on every interim result.
  static let volatileLineID = UUID()

  /// The session's published state as lines. The volatile tail is a line like
  /// any other — it groups with the turn it continues and differs only in how
  /// it is drawn.
  static func lines(
    segments: [LiveMeetingSession.LiveSegment],
    partial: String?,
    elapsed: TimeInterval
  ) -> [LiveTranscriptLine] {
    var lines = segments.map {
      LiveTranscriptLine(id: $0.id, text: $0.text, endTime: $0.endTime, speaker: nil)
    }
    if let partial, !partial.isEmpty {
      lines.append(
        LiveTranscriptLine(
          id: volatileLineID,
          text: partial,
          endTime: elapsed,
          // Continues whoever was last speaking; nil today, and nil is a
          // speaker value like any other as far as the grouping is concerned.
          speaker: lines.last?.speaker,
          isVolatile: true
        )
      )
    }
    return lines
  }

  /// Group consecutive lines by speaker. With no labels every line has the same
  /// (nil) speaker, so today this produces exactly one block and reads as the
  /// continuous transcript it is — the grouping is not waiting to be written,
  /// it is waiting to be *fed*.
  static func blocks(_ lines: [LiveTranscriptLine]) -> [LiveTranscriptBlock] {
    var blocks: [LiveTranscriptBlock] = []
    for line in lines {
      if var last = blocks.last, last.speaker == line.speaker {
        last.lines.append(line)
        blocks[blocks.count - 1] = last
      } else {
        blocks.append(
          LiveTranscriptBlock(
            id: line.id,
            speaker: line.speaker,
            startedAt: line.endTime,
            lines: [line]
          )
        )
      }
    }
    return blocks
  }

  /// The blocks, flattened into the rows the `LazyVStack` actually gets.
  ///
  /// One row per line, always — that is the invariant the laziness rests on —
  /// plus one header row per turn that has a speaker.
  /// `markedLineIDs` comes from `LiveTranscriptMarking`, which works on lines
  /// rather than blocks — the marking rule is about time, and blocks are a
  /// grouping by speaker. A speaker header row is never marked: the rule
  /// belongs beside the words that were being said, not beside a name.
  static func rows(
    _ blocks: [LiveTranscriptBlock],
    markedLineIDs: Set<UUID> = []
  ) -> [LiveTranscriptRow] {
    var rows: [LiveTranscriptRow] = []
    for block in blocks {
      // The gutter belongs to whichever row opens the turn: the speaker header
      // if there is one, otherwise the turn's first line.
      var gutter: TimeInterval? = block.startedAt
      if let speaker = block.speaker {
        rows.append(LiveTranscriptRow(id: .speaker(block.id), gutter: gutter, content: .speaker(speaker)))
        gutter = nil
      }
      for line in block.lines {
        rows.append(
          LiveTranscriptRow(
            id: .line(line.id),
            gutter: gutter,
            content: .line(line),
            isMarked: markedLineIDs.contains(line.id)
          )
        )
        gutter = nil
      }
    }
    return rows
  }

  /// "mm:ss" / "h:mm:ss" for the gutter — the same clock the timer runs, so a
  /// marker at 12:04 and a transcript line at 12:04 name the same instant.
  static func timestamp(_ interval: TimeInterval) -> String {
    SessionTimerMetrics.text(elapsed: interval)
  }
}

/// Memoizes the transcript's row model against the inputs that can change it.
///
/// `lines` → `blocks` → `rows` maps **every** segment of the session, so it is
/// O(all segments) — nothing when it runs on new text, ruinous when it runs on
/// a render the transcript did not cause. The pane's other publishers (the
/// elapsed ticker, and anything else that invalidates the window) would
/// otherwise rebuild 400 line structs to redraw a clock.
///
/// The key is cheap on purpose: a segment list is append-only, so its count and
/// its last id say everything about it, and `elapsed` reaches the model only as
/// the volatile line's gutter timestamp — which is drawn to the second.
@MainActor
final class LiveTranscriptRowCache {
  struct Key: Equatable {
    let segmentCount: Int
    let lastSegmentID: UUID?
    let partial: String?
    let elapsedSeconds: Int
    /// Every field of every marker, hashed — **not** the count.
    ///
    /// The count is what a list that is only ever appended to needs, and that
    /// is what the marker list is *today*. It is not what it will be: `label`
    /// is a `var` the auto-title follow-up fills **in place**, and against a
    /// count the transcript would then go on drawing the rows it built before
    /// the label existed until an unrelated segment arrived. A signature costs
    /// one pass over a list of tens and cannot be wrong about a mutation, which
    /// is the trade a memo of an O(all segments) rebuild should always take.
    let markerSignature: Int
  }

  /// The signature above. `at` is hashed by its bit pattern so two equal
  /// times can never hash apart.
  static func signature(of markers: [SessionMarker]) -> Int {
    var hasher = Hasher()
    hasher.combine(markers.count)
    for marker in markers {
      hasher.combine(marker.id)
      hasher.combine(marker.at.bitPattern)
      hasher.combine(marker.label)
    }
    return hasher.finalize()
  }

  /// How many times the model was really rebuilt. Exposed so a test can prove
  /// the cache is a cache rather than a wrapper around a recomputation.
  private(set) var recomputeCount = 0

  private var key: Key?
  private var rows: [LiveTranscriptRow] = []

  func rows(
    segments: [LiveMeetingSession.LiveSegment],
    partial: String?,
    elapsed: TimeInterval,
    markers: [SessionMarker] = []
  ) -> [LiveTranscriptRow] {
    let next = Key(
      segmentCount: segments.count,
      lastSegmentID: segments.last?.id,
      partial: partial,
      elapsedSeconds: elapsed.isFinite && elapsed > 0 ? Int(elapsed) : 0,
      markerSignature: Self.signature(of: markers)
    )
    if next == key { return rows }
    key = next
    let lines = LiveTranscript.lines(segments: segments, partial: partial, elapsed: elapsed)
    rows = LiveTranscript.rows(
      LiveTranscript.blocks(lines),
      markedLineIDs: LiveTranscriptMarking.markedLineIDs(markers: markers, lines: lines)
    )
    recomputeCount += 1
    return rows
  }
}

// MARK: - Controls

/// An action capsule: one glyph, one job, one colour, and exactly the height
/// every other capsule in the cluster has.
///
/// Internal rather than private because the claim it makes is about **pixels** —
/// that the colour survives the material being taken away — and only a rendered
/// button can answer that.
///
/// Three things it owes:
///
/// - **The height is the cluster's, as a hard frame.** A capsule that sized
///   itself to its glyph would be shorter than the timer beside it, and the row
///   would read as three unrelated controls. It is safe as a hard frame only
///   because `capsuleContentHeight` measured this face before reserving it.
/// - **The width is square at its minimum and grows for the count.** Icon only
///   is the owner's call; the moment count is the one thing that may widen a
///   capsule, and it widens the one it counts.
/// - **The tint is drawn over the glass, not through it.** See
///   `RecordingCapsuleTint`: a `Glass` tint is a property of the material and
///   goes with it under Reduce Transparency, and Stop is the one control that
///   may never be hard to find.
struct RecordingCapsuleButtonStyle: ButtonStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: RecordingPaneMetrics.actionIconSize, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, RecordingPaneMetrics.actionPaddingH)
      .frame(minWidth: RecordingPaneMetrics.capsuleHeight)
      .frame(height: RecordingPaneMetrics.capsuleHeight)
      .background(RecordingCapsuleTint.fill(tint), in: Capsule(style: .continuous))
      .craftGlassPanel(in: Capsule(style: .continuous))
      .opacity(configuration.isPressed ? 0.85 : 1)
  }
}

// MARK: - Marker list

/// The flagged moments, newest first.
///
/// **It has no caller on the recording surface, on purpose.** The cluster
/// dropped its Moments capsule on 2026-08-11 — you are recording, not browsing
/// — and nothing else in the app opens a marker list yet. It is kept rather
/// than deleted because **XIA-433** is the ticket that gives a mark a meaning
/// worth reading back (an auto-title from the surrounding transcript, persisted
/// on the record and carried into the summary), and this view is already
/// shaped for the row that lands then: a timestamp, and a label beside it when
/// there is one. Deleting it would cost that ticket a rewrite of a view whose
/// decisions were already argued.
///
/// The decisions worth keeping with it: the list used to sit at the bottom of
/// the session column, and neither a bar nor a capsule has a bottom to put it
/// at — hairlines down the transcript were the alternative and were refused as
/// a *list*, because a mark is a time and a set of hairlines you have to scroll
/// a live transcript to find is only findable if you already know where it is.
/// That refusal is about readback and it stands. XIA-433's ember rule is not
/// the thing that was refused: it is drawn beside the words that were being
/// said, it enumerates nothing, and it is gone the moment the microphone
/// closes — a marked-up transcript, not a way to browse moments. And this view
/// keeps its own `ScrollView`,
/// which the column's version explicitly did not: nesting two on one axis is
/// what that comment was avoiding, and unbounded it would outgrow whatever
/// eventually presents it.
struct SessionMarkerList: View {
  let markers: [SessionMarker]

  /// Wide enough for a timestamp and an auto-title (XIA-433) without the
  /// popover resizing as one arrives.
  static let width: CGFloat = 240
  /// About nine rows. Past that the list scrolls rather than the popover
  /// growing to whatever the session flagged.
  static let maxListHeight: CGFloat = 220

  var body: some View {
    VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
      Text(RecordingPaneCopy.markersHeading)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.ground(.speaker))
        .textCase(.uppercase)

      if markers.isEmpty {
        Text(RecordingPaneCopy.noMarkers)
          .font(RecordingPaneMetrics.markerLabelFont)
          .foregroundStyle(.ground(.timestamp))
      } else {
        // This list DOES get its own `ScrollView`, and the rule it used to break
        // no longer applies. XIA-443 wrote it without one because the 288pt
        // column already scrolled and two scroll views nested on one axis fight
        // over every wheel event; XIA-444 deleted the column and put the markers
        // in a popover, which scrolls nothing on its own. One scroll view on the
        // axis, still — the reason survived, the containing surface changed.
        ScrollView {
          VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
            ForEach(markers) { marker in
              HStack(spacing: CraftTokens.spacing8) {
                Text(LiveTranscript.timestamp(marker.at))
                  .font(RecordingPaneMetrics.markerTimeFont)
                  .foregroundStyle(.ground(.timestamp))
                if let label = RecordingPaneCopy.markerLabel(marker) {
                  Text(label)
                    .font(RecordingPaneMetrics.markerLabelFont)
                    .foregroundStyle(.ground(.body))
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.maxListHeight)
      }
    }
    .frame(width: Self.width, alignment: .leading)
    .padding(CraftTokens.spacing16)
  }
}

// MARK: - The capsule cluster

/// The timer capsule: **the meter and the clock, and nothing else.**
///
/// That is the owner's "C · Essential" (2026-08-11), chosen against three
/// fuller variants, and each omission has a reason worth keeping. The ember
/// **dot** went because the meter proves the same thing and proves it harder —
/// a dot is lit whether or not anything is being heard, and a meter with a
/// floor is the only thing on screen that can tell a live microphone from a
/// wedged one. The **kind** went because it is relabelable after Stop and
/// forbidden from changing anything visual, so during a session it is a word
/// that never moves and never does anything.
///
/// Clear glass, no tint: this capsule is information, and the two beside it are
/// actions.
struct SessionTimerCapsule: View {
  let elapsed: TimeInterval
  /// The meter's own object. Passed rather than a `Float` so the level's ~15 Hz
  /// feed is observed by `SessionMeterFeedView` alone — see `MeterPublishGate`.
  let level: MicLevelFeed
  /// Whether the microphone is open (XIA-447). Only the meter's colour depends
  /// on it — the clock keeps its own (frozen) value, and nothing about the
  /// capsule's geometry moves.
  var isLive: Bool = true

  var body: some View {
    HStack(spacing: RecordingPaneMetrics.timerContentGap) {
      SessionMeterFeedView(
        feed: level,
        variant: RecordingPaneMetrics.meterVariant,
        isLive: isLive
      )
      SessionTimer(elapsed: elapsed, base: RecordingPaneMetrics.clockBase)
    }
    .padding(.horizontal, RecordingPaneMetrics.timerPaddingH)
    .frame(height: RecordingPaneMetrics.capsuleHeight)
    .craftGlassPanel(in: Capsule(style: .continuous))
  }
}

/// The two jobs the cluster's action capsules do, as a table rather than as
/// closures buried in a view builder.
///
/// It exists because of the defect it replaces. The first cut collapsed
/// master's visible `Mark ⌘K` button and its separate moments button into one
/// capsule and gave the survivor the *other* one's action: the visible Mark
/// capsule opened the list, and `onMark` survived only on a zero-sized,
/// fully-transparent, `accessibilityHidden(true)` button behind the row. So a
/// mouse could not flag a moment at all, and VoiceOver could not either — the
/// one element that marked was removed from the tree, and the one it could
/// reach opened a list. Every geometry test in the file was green through it,
/// because none of them could see which action a capsule ran.
///
/// With the table, the cluster draws `allCases` in order and dispatches on the
/// case, so "which control does what" is one switch a test reads directly
/// rather than closures a rendered window would have to be driven to discover.
///
/// There is no `moments` case any more (owner, 2026-08-11): reviewing what has
/// been flagged is not something a recording surface does. See the cluster's
/// own comment for what went with it.
/// (XIA-447 added `pause`. The 2026-08-11 ruling against a fourth capsule was
/// about **Moments**, a browsing affordance on a surface meant for recording;
/// pause is a *capture control*, and that reasoning does not carry. XIA-422's
/// older rejection does not either: it found that people reaching for pause
/// wanted "this bit matters" and shipped Mark, which is a real need and not the
/// only one. Mark is an annotation and never stops capture; pause stops capture
/// and says nothing about importance. No reading of Mark serves "I want to use
/// the restroom for two minutes and then hit continue".)
enum SessionClusterAction: CaseIterable {
  /// Flag this instant, and carry the tally of what has been flagged.
  case mark
  /// Stop capturing without ending the session, and start again. **Stop stays
  /// terminal** — there is no resume after Stop, ever — which is why this is a
  /// separate control and not a mode of that one.
  case pause
  case stop

  /// The faces that depend on whether the session is paused take it as a
  /// parameter rather than the table splitting into two cases, one of which is
  /// undrawable at any given moment. The row is `allCases` in order, so a case
  /// that cannot be drawn is a hole in the row.
  func symbol(paused: Bool) -> String {
    switch self {
    case .mark: return "bookmark.fill"
    case .pause: return paused ? "play.fill" : "pause.fill"
    case .stop: return "stop.fill"
    }
  }

  /// The word drawn *beside* the glyph, when there is one. Only Pause has one,
  /// and only while paused.
  ///
  /// This is the state saying its own name on the control that will undo it
  /// (owner, 2026-08-12). It is deliberately not a face every capsule has: a
  /// title on Mark or Stop would be a second label competing with a glyph that
  /// is already unambiguous, and the row is icon-only precisely so the three
  /// controls read as one object.
  func title(paused: Bool) -> String? {
    self == .pause && paused ? RecordingPaneCopy.pausedTitle : nil
  }

  /// The accessibility label — an icon-only control's only name.
  func label(paused: Bool) -> String {
    switch self {
    case .mark: return RecordingPaneCopy.markTitle
    case .pause: return paused ? RecordingPaneCopy.resumeTitle : RecordingPaneCopy.pauseTitle
    case .stop: return RecordingPaneCopy.stopTitle
    }
  }

  /// The tooltip. Mark's names its shortcut, because icon-only leaves nowhere
  /// else on the surface for ⌘K to be written.
  func help(paused: Bool) -> String {
    self == .mark ? RecordingPaneCopy.markHelp : label(paused: paused)
  }

  /// Which states this capsule may be pressed in.
  ///
  /// It is back as a per-action question — XIA-445 removed it because every
  /// capsule then belonged to a running session and a property that can only
  /// say `true` reads as a question the surface is still asking. Pause makes it
  /// a real question again, and the answer is not uniform: **Mark is refused
  /// while paused**, because `NotaModel.markCurrentMoment` gates on the open
  /// microphone and a moment flagged into a paused session is a timestamp
  /// pointing at audio nobody kept. Pause and Stop are live in both.
  func isEnabled(_ controls: LiveMeetingControls) -> Bool {
    switch self {
    case .mark: return controls == .stop
    case .pause, .stop: return controls == .stop || controls == .paused
    }
  }

  /// Blue for the two confident actions (Mark and Pause), red for the one that
  /// ends the session. `CraftTokens.primaryBlue` is the app's "confident
  /// action" colour and sits at ΔE 132 from the ember, where no confusion is
  /// possible; Stop's red is the owner's call with the measurement in hand
  /// (`CraftTokens.stopRed`). Pause is deliberately **not** red and not ember:
  /// red is Stop and nothing else on this surface, and the ember means the
  /// microphone is open — which is the one thing pause is turning off.
  var tint: Color {
    self == .stop ? CraftTokens.stopRed : CraftTokens.primaryBlue
  }

  /// The count rides on the capsule that produces it. It used to ride on the
  /// capsule that *listed* them, and when that capsule went the tally stayed:
  /// it is the only feedback a press of ⌘K has.
  var carriesMarkerCount: Bool { self == .mark }
}

/// The recording surface: three sibling capsules floating over the transcript
/// (XIA-445).
///
/// Left to right the session, then what to do about it — the clock, Mark, Stop.
/// That is the bar's order and the column's before it; what changed is that the
/// row no longer takes a band of the window to say it.
///
/// **Three, and reviewing moments is deliberately not one of them** (owner,
/// 2026-08-11). A fourth capsule for the list was built and rejected: you are
/// recording, not browsing, and a control whose whole job is to read back what
/// you already flagged is not something the surface over a live transcript owes
/// you. Hanging the list off a long-press or a right-click of Mark was rejected
/// too, and for the older reason — that hides a whole affordance behind a
/// gesture nothing on screen names, on the one surface whose other rules are
/// that nothing moves and nothing is hidden. So the list is simply not reachable
/// while recording; **moment markers end to end are XIA-433**, which is where a
/// mark gets a meaning worth reading back.
///
/// What did **not** go with it is the **tally**, which now rides on Mark. It is
/// the only feedback a press of ⌘K has — with no count and no list, marking is
/// a button that does nothing observable — and keeping it was the one cost the
/// owner weighed against a fourth pill.
///
/// One `GlassEffectContainer` at the same spacing the `HStack` uses, because the
/// container's spacing *is* the merge distance: two numbers here would merge the
/// plates at a gap the eye does not see, or fail to merge at the one it does.
/// Nothing wraps the capsules — a capsule inside a capsule is not a doubled rim,
/// it is Liquid Glass silently auto-converted to a vibrant fill, which is a
/// failure with nothing on screen to announce it.
struct SessionCapsuleCluster: View {
  let elapsed: TimeInterval
  let level: MicLevelFeed
  let controls: LiveMeetingControls
  let markers: [SessionMarker]
  let onMark: () -> Void
  var onPause: () -> Void = {}
  let onStop: () -> Void

  /// The cluster has one size no longer — Pause grows into "Paused" — so this
  /// surface has a transition for an accessibility setting to reach for the
  /// first time. See `RecordingMotion.pauseAnimation`.
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Whether the session this cluster is drawing is paused. Read off the one
  /// decision every surface reads, so the capsule faces, the word and the
  /// enablement cannot disagree with each other.
  private var isPaused: Bool { controls == .paused }

  var body: some View {
    GlassEffectContainer(spacing: RecordingPaneMetrics.capsuleGap) {
      HStack(spacing: RecordingPaneMetrics.capsuleGap) {
        SessionTimerCapsule(elapsed: elapsed, level: level, isLive: !isPaused)
        ForEach(SessionClusterAction.allCases, id: \.self) { capsule($0) }
      }
      // The one thing on this surface that changes size. Driven from `isPaused`
      // rather than from the whole `controls` value so a marker landing or a
      // level tick cannot spring the row.
      .animation(RecordingMotion.pauseAnimation(reduceMotion: reduceMotion), value: isPaused)
    }
  }

  /// What each capsule does, in one place. This is the same call the button
  /// makes *and* a call a test can make on the view value without a window
  /// server — which is the only way "the visible Mark capsule flags a moment"
  /// can be asserted at all in this bundle: SwiftUI publishes no accessibility
  /// tree for an unhosted hosting view, measured on 2026-08-11, so walking for
  /// the labels proves nothing either way.
  func perform(_ action: SessionClusterAction) {
    switch action {
    case .mark: onMark()
    case .pause: onPause()
    case .stop: onStop()
    }
  }

  /// Internal for the reason `perform(_:)` is: the width claim below is about
  /// the capsules the cluster really draws, and a test that rebuilt the label
  /// itself would be measuring its own copy of the markup.
  @ViewBuilder
  func capsule(_ action: SessionClusterAction) -> some View {
    Button {
      perform(action)
    } label: {
      // The glyph, and — on Pause while paused — the word beside it. The
      // capsule is sized by this, in both states: the growth into the word is
      // the state change, not a cost to be engineered away (owner, 2026-08-13).
      HStack(spacing: RecordingPaneMetrics.pausedTitleGap) {
        Image(systemName: action.symbol(paused: isPaused))
        if let title = action.title(paused: isPaused) {
          Text(title)
            .font(.system(size: RecordingPaneMetrics.pausedTitleFontSize, weight: .semibold))
        }
      }
    }
    .buttonStyle(RecordingCapsuleButtonStyle(tint: action.tint))
    .overlay(alignment: .topTrailing) {
      if action.carriesMarkerCount { markerCount }
    }
    // Per-action again since XIA-447: Mark is refused while paused (a moment
    // flagged into a session whose audio is not being kept is a timestamp
    // pointing at nothing), while Pause and Stop are live in both states.
    .disabled(!action.isEnabled(controls))
    .accessibilityLabel(action.label(paused: isPaused))
    .accessibilityHint(action == .mark ? RecordingPaneCopy.markShortcut : "")
    .help(action.help(paused: isPaused))
    // ⌘K lives on the button that marks, now that the button that marks is the
    // one the owner can see. It went on a hidden zero-sized button only because
    // the visible capsule's press opened the list.
    .keyboardShortcut(action == .mark ? KeyboardShortcut("k", modifiers: .command) : nil)
  }

  /// The tally, as a **badge over** the Mark capsule rather than an element
  /// inside it.
  ///
  /// The rule it has to keep is that no count may move Stop. The first answer
  /// was a plate reserved from zero — `markerCountWidth`, always drawn, its
  /// *text* coming and going — and it kept the rule at a price the owner saw
  /// immediately: Mark then carried that plate and its gap permanently empty,
  /// so it drew 44pt against Stop's 23pt with its glyph pushed off centre, and
  /// a row of three capsules read as one lopsided pair (measured off the
  /// owner's screenshot, 2026-08-11).
  ///
  /// An overlay is not in the layout at all, so the rule stops being a
  /// reservation to keep in step with the digits and becomes a fact about where
  /// the count is drawn: Mark is square at every count, the ninth moment and
  /// the tenth cost the row exactly nothing, and there is no width to reserve
  /// for a number that is not there. `markerCountWidth` went with it.
  ///
  /// The tally rides on Mark since the Moments capsule went (2026-08-11), and
  /// it is the *whole* of the feedback a press of ⌘K gets — there is no list
  /// left to open, so a Mark that did not visibly count would be a button with
  /// no observable effect at all. Which is also why the badge sits **outside**
  /// the capsule's own accessibility label: `action.label` names what the
  /// control does, and the count is state, not a name that changes 40 times a
  /// session.
  @ViewBuilder
  private var markerCount: some View {
    if let count = RecordingPaneCopy.markerCount(markers) {
      Text(count)
        .font(.system(size: RecordingPaneMetrics.markerBadgeFontSize, weight: .semibold))
        .monospacedDigit()
        // White on white, not the notification badge's red: on this surface red
        // is Stop and the ember is the open microphone, and a third red thing
        // counting bookmarks would spend a colour that means something. It also
        // keeps `stopRedMinX` — the probe that proves Stop never moves — looking
        // at exactly one red shape.
        .foregroundStyle(CraftTokens.primaryBlue)
        .padding(.horizontal, RecordingPaneMetrics.markerBadgePaddingH)
        .frame(
          minWidth: RecordingPaneMetrics.markerBadgeDiameter,
          minHeight: RecordingPaneMetrics.markerBadgeDiameter
        )
        .background(.white, in: Capsule(style: .continuous))
        // Far enough out to clear the capsule's own rim on both edges, and no
        // further: a badge that floats free of its control belongs to nothing.
        .offset(x: RecordingPaneMetrics.markerBadgeInset, y: -RecordingPaneMetrics.markerBadgeInset)
        .allowsHitTesting(false)
    }
  }
}

// MARK: - Transcript

/// The live transcript: gutter timestamps, a speaker slot above each turn, the
/// volatile tail dimmed, newest text always in view.
struct LiveTranscriptView: View {
  /// Flat: every row here is a **direct** child of the `LazyVStack` below, which
  /// is the only arrangement in which the stack's laziness is worth anything.
  let rows: [LiveTranscriptRow]
  /// Chased separately from the row ids: the tail is rewritten on every interim
  /// result and the row's identity does not change when it does.
  let volatileID: UUID?
  /// Room kept clear at the bottom for the capsule cluster floating over this
  /// view (XIA-445). Zero for a transcript with nothing over it — the failed
  /// session's, which wears a banner instead.
  ///
  /// It is taken off the **scroll view's own frame**, and that is the whole of
  /// what makes it worth anything. It shipped as scroll *content* padding on
  /// the `LazyVStack`, which buys nothing here: `scrollToNewest` pins the
  /// newest row with `anchor: .bottom`, i.e. aligns that row's bottom with the
  /// bottom of the **visible region**, and padding that follows the last row in
  /// content space is simply offset the scroll view never needs to reach. So
  /// the newest line came to rest flush against the window's bottom edge and
  /// the one before it sat behind the glass, for the whole session, with the
  /// reservation constant green beside it.
  ///
  /// A frame inset over `safeAreaInset` / `contentMargins` on purpose, and the
  /// reason is that this number has to be **checkable**. SwiftUI's safe area is
  /// a SwiftUI-level value: measured on 2026-08-11, `.safeAreaInset(edge:
  /// .bottom)` left the backing `NSScrollView`'s frame, clip view and
  /// `contentInsets` all untouched at their full height, so no test in this
  /// bundle can tell it from the content padding that was already wrong.
  /// Shrinking the scroll view shows up as 317 of 400 and is asserted as such.
  /// It also happens to be the more literal reading of the owner's call —
  /// "Reserve space" — since nothing is ever drawn under the glass, not even
  /// mid-scroll.
  var bottomReserve: CGFloat = 0

  /// The ember is a function of the colour scheme alone (`CraftTokens.ember`),
  /// so the marked-line rule reads it here rather than through a token that
  /// would have to guess.
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: RecordingPaneMetrics.lineSpacing) {
          if rows.isEmpty {
            listeningPlaceholder
          }
          ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            rowView(row, isFirst: index == 0).id(row.id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, RecordingPaneMetrics.transcriptPaddingH)
        .padding(.top, RecordingPaneMetrics.transcriptPaddingV)
        .padding(.bottom, RecordingPaneMetrics.transcriptPaddingV)
      }
      // The scroll view ends here; the cluster floats in the band below it as a
      // sibling in the pane's `ZStack`, so the transcript still gives up no
      // width and no *drawn* height to it — only the bottom of its own frame.
      .padding(.bottom, bottomReserve)
      .onChange(of: rows.count) { _, _ in
        scrollToNewest(proxy)
      }
      .onChange(of: rows.last) { _, _ in
        scrollToNewest(proxy)
      }
    }
  }

  private func scrollToNewest(_ proxy: ScrollViewProxy) {
    if let volatileID {
      proxy.scrollTo(LiveTranscriptRow.ID.line(volatileID), anchor: .bottom)
    } else if let last = rows.last {
      proxy.scrollTo(last.id, anchor: .bottom)
    }
  }

  private var listeningPlaceholder: some View {
    HStack(spacing: CraftTokens.spacing8) {
      Image(systemName: "waveform")
        .symbolEffect(.pulse, isActive: true)
        .foregroundStyle(.ground(.speaker))
      Text(RecordingPaneCopy.listening)
        .font(RecordingPaneMetrics.transcriptFont)
        .foregroundStyle(.ground(.speaker))
    }
  }

  /// One row: the gutter cell, then either a speaker name or a line of text.
  ///
  /// The speaker slot is a real row rather than a comment about a future one.
  /// Today no line carries a speaker and no such row is ever emitted; the day
  /// the pipeline fills the labels in, names appear and not one number in
  /// `RecordingPaneMetrics` moves.
  private func rowView(_ row: LiveTranscriptRow, isFirst: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: RecordingPaneMetrics.gutterGap) {
      // The cell is reserved on every row and filled only where a turn starts,
      // so a continuation never steps left under the line above it.
      Text(row.gutter.map(LiveTranscript.timestamp) ?? "")
        .font(RecordingPaneMetrics.gutterFont)
        .foregroundStyle(.ground(.timestamp))
        .frame(width: RecordingPaneMetrics.gutterWidth, alignment: .trailing)

      switch row.content {
      case .speaker(let name):
        Text(name)
          .font(RecordingPaneMetrics.speakerFont)
          .foregroundStyle(.ground(.speaker))
          .frame(maxWidth: .infinity, alignment: .leading)
      case .line(let line):
        // The volatile tail is **a tier, not an `.opacity()` on the body tier**.
        // It used to be body at 55%, which is a number nobody measured — a hair
        // under the timestamp tier's 56% and off the table entirely. It cleared
        // 3.0:1 (the solve needs 54% light, 40% dark); what it did not have was
        // a measurement, on the one line that is being read while it is written.
        // The tier is visually the same dimming and is on the swept side of it.
        Text(line.text)
          .font(RecordingPaneMetrics.transcriptFont)
          .foregroundStyle(.ground(line.isVolatile ? .timestamp : .body))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    // The ember rule for a flagged moment (XIA-433). An **overlay**, so it
    // occupies no layout at all: a mark that landed mid-sentence may not move
    // the sentence it landed in, and a row that has one is exactly the size of
    // a row that has not. It rides in the left margin the transcript's own
    // horizontal padding already reserves, so it costs the text no width
    // either.
    //
    // **The ember still means one thing.** A row can only arrive here marked
    // while the microphone is open: `LiveMeetingView.drawnMarkers` withholds
    // the whole list from every state that is not recording or finalizing, so
    // a failed session's transcript — which is drawn by this same view, with
    // the session's marks still in the log — carries no ember at all. Inside a
    // live session the rule is not a second meaning but a location for the one
    // meaning there is: this is where the owner flagged something while we
    // were capturing.
    .overlay(alignment: .leading) {
      if row.isMarked {
        Capsule(style: .continuous)
          .fill(CraftTokens.ember(colorScheme))
          .frame(width: RecordingPaneMetrics.markerRuleWidth)
          .offset(x: -RecordingPaneMetrics.markerRuleInset)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    // A flat stack has no blocks left to space apart, so the gap between turns
    // is paid by the row that opens one.
    .padding(.top, row.startsTurn && !isFirst
      ? RecordingPaneMetrics.blockSpacing - RecordingPaneMetrics.lineSpacing
      : 0)
  }
}

// MARK: - Previews

#if DEBUG
private func previewRows() -> [LiveTranscriptRow] {
  LiveTranscript.rows(previewBlocks())
}

private func previewBlocks() -> [LiveTranscriptBlock] {
  LiveTranscript.blocks([
    LiveTranscriptLine(id: UUID(), text: "Right, so the migration lands next Tuesday.", endTime: 12, speaker: "Amara"),
    LiveTranscriptLine(id: UUID(), text: "We still owe the rollback note.", endTime: 19, speaker: "Amara"),
    LiveTranscriptLine(id: UUID(), text: "I can write that this afternoon.", endTime: 27, speaker: "Kenny"),
    LiveTranscriptLine(id: LiveTranscript.volatileLineID, text: "and I'll ping the on-call", endTime: 31, speaker: "Kenny", isVolatile: true),
  ])
}

private struct RecordingPaneGallery: View {
  let kind: HistoryKind

  var body: some View {
    CraftWashBackground()
      .overlay(
        ZStack(alignment: .bottom) {
          LiveTranscriptView(
            rows: previewRows(),
            volatileID: LiveTranscript.volatileLineID,
            bottomReserve: RecordingPaneMetrics.transcriptBottomReserve
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)

          SessionCapsuleCluster(
            elapsed: 754,
            level: MicLevelFeed(level: 0.6),
            controls: .stop,
            markers: [SessionMarker(at: 612), SessionMarker(at: 208)],
            onMark: {},
            onStop: {}
          )
          .padding(.bottom, RecordingPaneMetrics.clusterBottomInset)
        }
      )
  }
}

#Preview("recording pane – light") {
  RecordingPaneGallery(kind: .meeting)
    .frame(width: 980, height: 620)
    .preferredColorScheme(.light)
}

#Preview("recording pane – dark") {
  RecordingPaneGallery(kind: .meeting)
    .frame(width: 980, height: 620)
    .preferredColorScheme(.dark)
}

/// Past the hour, and with no moments flagged: the clock steps to `h:mm:ss`
/// inside a plate that was reserved for it, and Mark draws its tally plate
/// empty — the width it will still have at the first ⌘K, and at the tenth.
#Preview("recording cluster – past the hour") {
  CraftWashBackground()
    .overlay(
      SessionCapsuleCluster(
        elapsed: 3754,
        level: MicLevelFeed(level: 0.6),
        controls: .stop,
        markers: [],
        onMark: {},
        onStop: {}
      )
    )
    .frame(width: 980, height: 240)
    .preferredColorScheme(.dark)
}
#endif
