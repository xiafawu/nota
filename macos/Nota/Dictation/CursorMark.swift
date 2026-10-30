import CoreGraphics
import Foundation

// MARK: - The Cursor HUD style, as arithmetic
//
// Everything about the Cursor style that can be decided without a window
// server lives here: which phase the mark is in, when the voice counts as
// heard, how long a problem note stays, where the mark goes and what it falls
// back to when the caret cannot be read. `CursorMarkPanel.swift` is the AppKit
// half and only renders what these types decide.
//
// Owner, 2026-10-30: no preview text. While a session runs, one Liquid Glass
// capsule sits at the text caret — a breathing dot while quiet, a five-bar
// waveform while the voice is heard, a wave rolling through the bars while a
// sentence is processed — and the text lands at the caret with the mark
// following it. On release it fades. A problem tints it amber or red with a
// one-line note beside it for about four seconds.

// MARK: - Position setting

/// Where the mark sits relative to the caret.
enum CursorMarkPosition: String, Codable, CaseIterable, Sendable {
  /// Just after the caret, vertically centred on its line. The default.
  case beside
  /// Under the caret, centred on it.
  case below

  static let standard: CursorMarkPosition = .beside

  var label: String {
    switch self {
    case .beside: return "Beside cursor"
    case .below: return "Below cursor"
    }
  }
}

// MARK: - Phase

/// A problem the mark reports: the tint and the one-line note beside it.
struct CursorProblem: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case warning
    case error
  }

  let kind: Kind
  let message: String
}

/// What the mark is showing.
enum CursorMarkPhase: Equatable, Sendable {
  case hidden
  /// A session is up and nothing is being heard: the breathing dot.
  case quiet
  /// The voice is heard: the waveform follows the level.
  case talking
  /// A sentence is being processed: a wave rolls through the bars.
  case working
  /// Tinted, with the note beside it.
  case problem(CursorProblem)

  /// The waveform shapes are the wide capsule; the dot and a problem are not.
  var isWide: Bool {
    switch self {
    case .talking, .working: return true
    case .hidden, .quiet, .problem: return false
    }
  }

  /// A phase that belongs to a running session (as opposed to its aftermath).
  var isSession: Bool {
    switch self {
    case .quiet, .talking, .working: return true
    case .hidden, .problem: return false
    }
  }

  var problem: CursorProblem? {
    if case .problem(let problem) = self { return problem }
    return nil
  }

  /// Decide the phase from one controller snapshot.
  ///
  /// The same inputs `HUDState.compute` reads, plus the three only this style
  /// needs: whether the session is still starting (the mark is up from the
  /// press, before the recognizer is ready — "Fn down → dot at caret"),
  /// whether the voice gate is open, and how many sentences are on their way
  /// to the target.
  ///
  /// `isReviewing` outranks everything, as it does for every other style:
  /// Review Before Inserting has its card, and the card is that session's one
  /// surface. Talking outranks working — the owner's own voice is the thing
  /// they are watching for — and working is shown only between the voice and
  /// the delivery, or after the key is up.
  static func compute(
    controllerState: DictationState,
    isStartingSession: Bool,
    isReviewing: Bool,
    voiceHeard: Bool,
    sentencesInFlight: Int,
    isPolishInProgress: Bool,
    lastPolishWarning: String?,
    lastSecureFieldNotice: String?
  ) -> CursorMarkPhase {
    if isReviewing { return .hidden }

    switch controllerState {
    case .disabled:
      return .hidden

    case .idle:
      if isStartingSession { return .quiet }
      if let warning = lastPolishWarning, !warning.isEmpty {
        return .problem(CursorProblem(kind: .warning, message: warning))
      }
      if let notice = lastSecureFieldNotice, !notice.isEmpty {
        return .problem(CursorProblem(kind: .warning, message: notice))
      }
      // A clean finish shows nothing: the text is at the caret already.
      return .hidden

    case .listening:
      if voiceHeard { return .talking }
      if sentencesInFlight > 0 || isPolishInProgress { return .working }
      return .quiet

    case .finalizing, .injecting:
      return .working

    case .failed(let message):
      // A press after a failure starts a session again from `.failed`; the
      // press wins over the failure it is replacing.
      if isStartingSession { return .quiet }
      return .problem(CursorProblem(kind: .error, message: message))
    }
  }
}

// MARK: - Voice gate

/// When the level counts as "the voice is heard".
///
/// Hysteresis plus a hangover, because the mark changes *shape* on it: a gate
/// on one threshold flips between dot and waveform on every gap between words,
/// and a 20 ↔ 40 pt capsule doing that at speech rate is a flicker, not a
/// signal. It opens on a clear level, and it closes only after the level has
/// stayed under a lower one for `hangover` — longer than the gap between two
/// words, shorter than the pause at the end of a sentence.
///
/// The level is `MicCapture.rmsLevel`: dBFS mapped from −50…0 onto 0…1 and
/// already smoothed (fast attack, slow release). 0.30 is about −35 dBFS, 0.20
/// about −40. Chosen against that mapping, not measured against a room — the
/// owner's microphone is the check.
struct CursorVoiceGate: Equatable {
  static let openLevel: Float = 0.30
  static let closeLevel: Float = 0.20
  static let hangover: TimeInterval = 0.45

  private(set) var isOpen = false
  private var quietSince: TimeInterval?

  mutating func update(level: Float, now: TimeInterval) -> Bool {
    if level >= Self.openLevel {
      isOpen = true
      quietSince = nil
      return true
    }
    guard isOpen else { return false }
    if level >= Self.closeLevel {
      quietSince = nil
      return true
    }
    let since = quietSince ?? now
    quietSince = since
    if now - since >= Self.hangover {
      isOpen = false
      quietSince = nil
    }
    return isOpen
  }

  mutating func reset() {
    isOpen = false
    quietSince = nil
  }
}

// MARK: - Lifecycle

/// What the mark actually displays, given the phase the controller implies.
///
/// The one piece of memory the style needs: a problem is shown for
/// `problemDuration` and then consumed, because the controller's warning and
/// failure fields stay set while it sits idle — without the latch the same
/// note would come straight back on the next tick. A new session clears it,
/// exactly as `DictationHUDController.consumedState` does for the pill.
///
/// Four seconds rather than the pill's 3 s / 6 s: the note is one line beside
/// the caret, read at a glance, and the owner's call on the prototype.
struct CursorMarkLifecycle: Equatable {
  static let problemDuration: TimeInterval = 4.0

  private var shown: CursorProblem?
  private var shownAt: TimeInterval = 0
  private var consumed: CursorProblem?

  /// When the shown problem expires, or nil when none is showing. The caller
  /// re-asks at this moment so the note goes away without waiting for a tick.
  var expiry: TimeInterval? { shown == nil ? nil : shownAt + Self.problemDuration }

  mutating func display(_ phase: CursorMarkPhase, now: TimeInterval) -> CursorMarkPhase {
    switch phase {
    case .quiet, .talking, .working:
      shown = nil
      consumed = nil
      return phase
    case .hidden:
      shown = nil
      return .hidden
    case .problem(let problem):
      if problem == consumed { return .hidden }
      if problem == shown {
        guard now - shownAt < Self.problemDuration else {
          consumed = problem
          shown = nil
          return .hidden
        }
        return phase
      }
      shown = problem
      shownAt = now
      return phase
    }
  }
}

// MARK: - Metrics

/// Sizes and timings for the mark, from the owner-approved prototype.
enum CursorMarkMetrics {
  /// The capsule's height, in every phase.
  static let height: CGFloat = 20
  /// The dot: a 20 pt circle.
  static let quietWidth: CGFloat = 20
  /// The waveform.
  static let wideWidth: CGFloat = 40
  /// The breathing core of the dot.
  static let coreDiameter: CGFloat = 6

  static let barCount = 5
  static let barWidth: CGFloat = 2.5
  static let barSpacing: CGFloat = 2.5
  static let barBase: CGFloat = 3
  static let barMax: CGFloat = 14
  /// Centre-weighted, the family of the HUD meter's silhouette.
  static let profile: [CGFloat] = [0.45, 0.75, 1.0, 0.75, 0.45]

  /// Transparent room around the glass inside the window, where its rim and
  /// shadow fall. A window cannot draw outside its own frame.
  static let glassMargin: CGFloat = 12

  /// Gap between the caret and the mark beside it.
  static let besideGap: CGFloat = 8
  /// Gap between the caret's line and the mark below it.
  static let belowGap: CGFloat = 5
  /// Inset of the mark from the focused element's bottom-right corner.
  static let elementInset: CGFloat = 8
  /// Smallest gap kept between the mark and the edge of the visible screen.
  static let screenInset: CGFloat = 8

  /// The problem note beside the mark.
  static let noteHeight: CGFloat = 24
  static let noteGap: CGFloat = 6
  static let noteMaxWidth: CGFloat = 320
  static let noteHorizontalPadding: CGFloat = 10
  static let noteFontSize: CGFloat = 12.5

  /// The 20 ↔ 40 pt morph.
  static let morphDuration: TimeInterval = 0.26
  /// Following the caret.
  static let moveDuration: TimeInterval = 0.16

  /// How often the caret is re-read while the mark is up. Each read is an AX
  /// round-trip into the target app, so it is modest, and it runs only while a
  /// session (or its problem note) is on screen — never on an always-on timer.
  static let pollInterval: TimeInterval = 0.2
  /// How long after text lands before the caret is re-read: the target app
  /// needs a beat to move its own caret and publish it.
  static let landedReadDelay: TimeInterval = 0.06

  static func width(for phase: CursorMarkPhase) -> CGFloat {
    phase.isWide ? wideWidth : quietWidth
  }

  /// One bar while the voice is heard: the level through the centre-weighted
  /// profile, plus the HUD meters' shared idle breathing so a held vowel never
  /// reads as frozen.
  static func talkingBarHeight(level: Float, index: Int, breathe: Double) -> CGFloat {
    let clamped = CGFloat(min(max(level, 0), 1))
    let shape = profile[index % profile.count]
    let drive = clamped * shape + CGFloat(breathe)
    return min(barMax, max(barBase, barBase + (barMax - barBase) * drive))
  }

  /// Radians per second the working wave travels at, and the phase step
  /// between neighbours — the prototype's roll, restated in seconds.
  static let waveSpeed: Double = 7.0
  static let waveStep: Double = 0.9
  static let waveAmplitude: CGFloat = 8

  /// One bar while a sentence is processed: a crest rolling left to right.
  ///
  /// Under Reduce Motion the wave holds still at a uniform mid height. The
  /// shape still says "working" — a wide capsule with even bars is neither
  /// the dot nor a voice — and only the motion goes, which is the ring's
  /// answer rather than the meter's: the roll carries no information the
  /// stillness loses.
  static func rollingBarHeight(index: Int, time: TimeInterval, reduceMotion: Bool) -> CGFloat {
    guard !reduceMotion else { return barBase + waveAmplitude / 2 }
    let crest = max(0, sin(time * waveSpeed - Double(index) * waveStep))
    return barBase + waveAmplitude * CGFloat(crest)
  }

  /// The quiet dot's breathing scale. Decoration, so Reduce Motion stops it.
  static func coreScale(time: TimeInterval, reduceMotion: Bool) -> CGFloat {
    guard !reduceMotion else { return 1 }
    return 0.85 + 0.25 * CGFloat(0.5 + 0.5 * sin(time * 1.4))
  }
}

// MARK: - Placement

/// What the mark is placed against, best first.
enum CursorAnchor: Equatable, Sendable {
  /// The caret itself, from `kAXBoundsForRangeParameterizedAttribute`.
  case caret(CGRect)
  /// The focused element's frame, when the app answers for the element but
  /// not for the caret — most Chromium and Electron web content.
  case element(CGRect)
  /// The pill's usual spot: a bottom-centre point, when nothing about the
  /// target could be read.
  case fallback(CGPoint)
}

/// Where the mark goes, as arithmetic on Cocoa (bottom-left origin) screen
/// rects. No `NSScreen`, no window server.
enum CursorMarkPlacement {
  /// The best anchor the reading supports.
  static func anchor(caret: CGRect?, element: CGRect?, fallback: CGPoint) -> CursorAnchor {
    if let caret { return .caret(caret) }
    if let element { return .element(element) }
    return .fallback(fallback)
  }

  /// The mark's rect for `anchor`, `width` wide, kept wholly on `visibleFrame`.
  ///
  /// Which edge holds still while the width morphs is part of the answer:
  ///
  /// - **Beside**: the left edge, `besideGap` after the caret, so the waveform
  ///   grows away from the text rather than over it. If that would leave the
  ///   screen it flips to the caret's left side and holds its right edge there.
  /// - **Below**: the centre, on the caret's x, so it grows symmetrically under
  ///   the caret it belongs to.
  /// - **Element**: the right edge, inside the element's bottom-right corner,
  ///   so the morph never pushes it out of the field.
  /// - **Fallback**: the centre, the way the pill hangs.
  static func markFrame(
    anchor: CursorAnchor,
    width: CGFloat,
    position: CursorMarkPosition,
    visibleFrame: CGRect
  ) -> CGRect {
    let height = CursorMarkMetrics.height
    var rect: CGRect
    switch anchor {
    case .caret(let caret):
      switch position {
      case .beside:
        let y = caret.midY - height / 2
        var x = caret.maxX + CursorMarkMetrics.besideGap
        if x + width > visibleFrame.maxX - CursorMarkMetrics.screenInset {
          x = caret.minX - CursorMarkMetrics.besideGap - width
        }
        rect = CGRect(x: x, y: y, width: width, height: height)
      case .below:
        rect = CGRect(
          x: caret.minX - width / 2,
          y: caret.minY - CursorMarkMetrics.belowGap - height,
          width: width,
          height: height
        )
      }
    case .element(let element):
      rect = CGRect(
        x: element.maxX - CursorMarkMetrics.elementInset - width,
        y: element.minY + CursorMarkMetrics.elementInset,
        width: width,
        height: height
      )
    case .fallback(let point):
      rect = CGRect(x: point.x - width / 2, y: point.y, width: width, height: height)
    }
    return clamped(rect, to: visibleFrame)
  }

  /// The note's rect beside `mark`: after it, vertically centred on it, and on
  /// its left instead when the right side has no room.
  static func noteFrame(mark: CGRect, noteSize: CGSize, visibleFrame: CGRect) -> CGRect {
    let width = min(noteSize.width, CursorMarkMetrics.noteMaxWidth)
    let height = max(noteSize.height, CursorMarkMetrics.noteHeight)
    var x = mark.maxX + CursorMarkMetrics.noteGap
    if x + width > visibleFrame.maxX - CursorMarkMetrics.screenInset {
      x = mark.minX - CursorMarkMetrics.noteGap - width
    }
    let rect = CGRect(x: x, y: mark.midY - height / 2, width: width, height: height)
    return clamped(rect, to: visibleFrame)
  }

  /// The pill's usual spot for a mark-sized surface: centred under the focused
  /// window (or the screen), resting where `HUDPanelLayout` rests the pill.
  /// The bottom-centre point `CursorAnchor.fallback` carries.
  static func fallbackPoint(windowFrame: CGRect?, visibleFrame: CGRect) -> CGPoint {
    let x = windowFrame?.midX ?? visibleFrame.midX
    let y = HUDPanelLayout.pillOriginY(
      anchorMinY: windowFrame?.minY,
      screenFrame: visibleFrame,
      pillHeight: CursorMarkMetrics.height,
      reservedHeight: CursorMarkMetrics.height
    )
    return CGPoint(x: x, y: y)
  }

  /// Shift (never resize) `rect` so it sits `screenInset` inside `visible`.
  static func clamped(_ rect: CGRect, to visible: CGRect) -> CGRect {
    let inset = CursorMarkMetrics.screenInset
    guard rect.width + inset * 2 <= visible.width,
          rect.height + inset * 2 <= visible.height
    else { return rect }
    var result = rect
    result.origin.x = min(max(result.minX, visible.minX + inset), visible.maxX - inset - rect.width)
    result.origin.y = min(max(result.minY, visible.minY + inset), visible.maxY - inset - rect.height)
    return result
  }
}

// MARK: - Caret geometry

/// Making sense of what an Accessibility server says about its caret.
///
/// AX answers are another process's word, and many are wrong in the same few
/// ways: a zero rect for a collapsed range, a rect at the screen origin, a rect
/// hundreds of points tall for a whole text view, or garbage from an app that
/// half-implements the attribute. Every one of those must fall through to the
/// next rung of the fallback chain rather than put the mark somewhere silly.
enum CaretGeometry {
  /// The tallest a caret line can plausibly be. Anything taller is the whole
  /// text area answering for a collapsed range.
  static let maxCaretHeight: CGFloat = 200
  static let minCaretHeight: CGFloat = 2

  /// AX rects are top-left origin (y down from the top of the primary screen);
  /// Cocoa's are bottom-left. Same flip `frontmostAppFocusedWindowFrame` makes.
  static func cocoaRect(fromAX rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
    CGRect(
      x: rect.minX,
      y: primaryScreenMaxY - rect.minY - rect.height,
      width: rect.width,
      height: rect.height
    )
  }

  /// A caret rect (zero width allowed) from what the server answered for the
  /// collapsed range, else the character before it, else the one after it.
  ///
  /// Many servers return an error or a zero-height rect for a zero-length
  /// range — the common case, an insertion point with nothing selected — while
  /// answering properly for a one-character range. The caret is then the
  /// trailing edge of the character before it, or the leading edge of the one
  /// after it at the start of a field.
  static func caret(collapsed: CGRect?, preceding: CGRect?, following: CGRect?) -> CGRect? {
    if let collapsed, isPlausibleLine(collapsed) {
      return CGRect(x: collapsed.minX, y: collapsed.minY, width: 0, height: collapsed.height)
    }
    if let preceding, isPlausibleLine(preceding) {
      return CGRect(x: preceding.maxX, y: preceding.minY, width: 0, height: preceding.height)
    }
    if let following, isPlausibleLine(following) {
      return CGRect(x: following.minX, y: following.minY, width: 0, height: following.height)
    }
    return nil
  }

  /// Whether `rect` could be one line of text on a screen.
  static func isPlausibleLine(_ rect: CGRect) -> Bool {
    guard rect.minX.isFinite, rect.minY.isFinite,
          rect.width.isFinite, rect.height.isFinite
    else { return false }
    guard rect.height >= minCaretHeight, rect.height <= maxCaretHeight,
          rect.width >= 0
    else { return false }
    // The origin with a degenerate size is the classic "not implemented" answer.
    if rect.origin == .zero { return false }
    return true
  }

  /// The caret, kept only when it plausibly belongs to the focused element and
  /// to a screen.
  ///
  /// A caret far outside its own element is a server answering in the wrong
  /// coordinate space (some report element-relative or flipped values); a
  /// caret on no screen at all is unusable whatever its source. Both fall
  /// through to the element rung.
  static func validated(
    caret: CGRect?,
    element: CGRect?,
    screens: [CGRect]
  ) -> CGRect? {
    guard let caret else { return nil }
    let point = CGPoint(x: caret.minX, y: caret.midY)
    guard screens.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(point) }) else {
      return nil
    }
    if let element, element.width > 0, element.height > 0 {
      let slack = max(caret.height, 24)
      guard element.insetBy(dx: -slack, dy: -slack).contains(point) else { return nil }
    }
    return caret
  }

  /// An element frame worth anchoring to: on a screen, and big enough to be a
  /// text field rather than a zero rect.
  static func validated(element: CGRect?, screens: [CGRect]) -> CGRect? {
    guard let element, element.width >= 4, element.height >= 4,
          element.minX.isFinite, element.minY.isFinite
    else { return nil }
    guard screens.contains(where: { $0.intersects(element) }) else { return nil }
    return element
  }
}
