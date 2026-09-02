import AppKit
import SwiftUI

// MARK: - Motion

/// What Reduce Motion means on a recording surface, written down once.
///
/// The two components answer it **differently**, and the asymmetry is the whole
/// point rather than an oversight:
///
/// - The **meter** is information. It is the only proof on screen that the
///   microphone is actually open and hearing something, so it keeps moving
///   under Reduce Motion — with a plainer curve (no spring overshoot), but it
///   moves. Freezing it would not calm the interface; it would make a live
///   session and a wedged one look identical.
/// - The **ring** is decoration. It breathes because a live session should feel
///   alive, and nothing is lost by holding it still — the meter is already
///   saying the thing the ring is only dressing up.
/// There used to be a third entry here — the recording bar's hover bloom
/// (XIA-444), which snapped rather than travelled under Reduce Motion. The bar
/// is gone (XIA-445) and the capsule cluster has exactly one size, so there is
/// no transition left to have an opinion about. The asymmetry above is what
/// survives, and it survives whole: it is about what a *live microphone* is
/// allowed to look like, not about the shape drawn around it.
///
/// Both live here so a future component has to pick a side deliberately.
enum RecordingMotion {
  /// Never nil, at either setting: the meter always animates.
  static func meterAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion
      ? .linear(duration: 0.10)
      : .spring(response: 0.28, dampingFraction: 0.55)
  }

  /// Nil under Reduce Motion: the Pause capsule takes its two widths as a cut.
  ///
  /// This is the ring's answer rather than the meter's, and the reason is the
  /// same asymmetry: the meter must keep moving because a frozen meter and a
  /// wedged microphone look identical, whereas nothing here is lost to a cut —
  /// the word "Paused" is on screen either way, and the state it names is also
  /// on the menu bar and the island. What the animation buys is only that the
  /// two neighbours look pushed rather than teleported.
  /// **The numbers are the owner's, picked off the running curves** (2026-08-13).
  /// The first cut shipped `0.32 / 0.82` and read "too fast and rigid" — which
  /// is what a tightly damped spring is: it arrives and stops dead, with no
  /// settle for the eye to follow. Four candidates were rendered side by side
  /// on the real cluster geometry, each solved as a damped harmonic so the
  /// settle on the page was the settle the app draws, and this is the one
  /// chosen: the longest open of the four, with visible give at the end.
  static func pauseAnimation(reduceMotion: Bool) -> Animation? {
    guard !reduceMotion else { return nil }
    return .spring(response: 0.70, dampingFraction: 0.62)
  }

  /// The word fades in over the first 70% of the growth rather than arriving at
  /// full strength the instant the press lands. Half of what read as rigid was
  /// the *content* being instantaneous while the box was not — the capsule
  /// opened onto a word that was already finished.
  static func pauseTitleAnimation(reduceMotion: Bool) -> Animation? {
    guard !reduceMotion else { return nil }
    return .easeInOut(duration: 0.70 * 0.7)
  }

  /// False under Reduce Motion: a decorative SF Symbol pulse holds still.
  ///
  /// This is the ring's answer, and for the ring's reason (P-B6). The pulsing
  /// waveform beside "Listening" on the live transcript, and the one on the
  /// running view's icon, say nothing the surface is not already saying in
  /// words — they are the ring's category, not the meter's. The waveform's
  /// `isActive` was literally `true`, so nothing could stop it.
  static func decorationPulses(reduceMotion: Bool) -> Bool { !reduceMotion }

  /// Nil under Reduce Motion: the ring holds at a steady scale and opacity.
  static func ringAnimation(reduceMotion: Bool) -> Animation? {
    guard !reduceMotion else { return nil }
    return .easeInOut(duration: SessionRingMetrics.cycle / 2).repeatForever(autoreverses: true)
  }
}

// MARK: - Session meter

/// Sizing for `SessionMeter`, kept out of the view for the reason
/// `HUDPillMetrics` and `HUDPrompterMetrics` are: the arithmetic is then
/// asserted without a window server, a hosting view, or a microphone.
enum SessionMeterMetrics {
  /// Two sizes, not a free `height` parameter. The in-window recording column
  /// and the mini-recorder/menu-bar island are the only two places this appears,
  /// and a meter whose bar count varies continuously has no baseline to pin.
  enum Variant: CaseIterable {
    /// Beside the big timer in the recording column.
    case tall
    /// Beside a timer in the floating island or the menu bar.
    case compact

    var barCount: Int {
      switch self {
      case .tall: return 9
      case .compact: return 5
      }
    }

    var barWidth: CGFloat {
      switch self {
      case .tall: return 3
      case .compact: return 2
      }
    }

    var barSpacing: CGFloat {
      switch self {
      case .tall: return 3
      case .compact: return 2
      }
    }

    /// The floor a silent room draws — the meter is never blank, because a
    /// blank meter and an absent meter look the same.
    var minBarHeight: CGFloat {
      switch self {
      case .tall: return 4
      case .compact: return 3
      }
    }

    var maxBarHeight: CGFloat {
      switch self {
      case .tall: return 48
      case .compact: return 16
      }
    }

    /// Fixed overall width, so the meter cannot resize the row it sits in when
    /// a bar happens to round differently.
    var width: CGFloat {
      let n = CGFloat(barCount)
      return n * barWidth + (n - 1) * barSpacing
    }
  }

  /// Every bar's height for one RMS reading.
  ///
  /// `reduceMotion` is deliberately **not** a parameter: the heights are what
  /// the microphone is doing, and that is not a motion preference. Only the
  /// curve between two readings is (`RecordingMotion.meterAnimation`).
  static func barHeights(level: Float, variant: Variant) -> [CGFloat] {
    (0..<variant.barCount).map { barHeight(level: level, index: $0, variant: variant) }
  }

  static func barHeight(level: Float, index: Int, variant: Variant) -> CGFloat {
    let clamped = CGFloat(min(max(level, 0), 1))
    let shape = profile(index: index, count: variant.barCount)
    // A touch of per-bar wobble driven by the level itself, so the silhouette
    // is a voice and not a symmetric hill. Deterministic: the same level always
    // draws the same meter.
    let wobble = 0.75 + 0.25 * sin(Double(index) * 1.7 + Double(clamped) * 21)
    let drive = clamped * shape * CGFloat(wobble)
    let span = variant.maxBarHeight - variant.minBarHeight
    return min(variant.maxBarHeight, variant.minBarHeight + span * drive)
  }

  /// Center-weighted silhouette, same family as the HUD's compact meter but
  /// generated for any bar count.
  private static func profile(index: Int, count: Int) -> CGFloat {
    guard count > 1 else { return 1 }
    let t = (Double(index) + 0.5) / Double(count)
    return CGFloat(0.42 + 0.58 * sin(.pi * t))
  }
}

/// The live level meter: proof the microphone is open, in ember.
struct SessionMeter: View {
  let level: Float
  var variant: SessionMeterMetrics.Variant = .tall
  /// Whether the microphone this meter is drawing is **open** (XIA-447).
  ///
  /// It changes the colour and nothing else. The bars stay — the meter is a
  /// fixed frame and the floor is drawn whatever the level, because a blank
  /// meter and an absent meter look the same — but a paused session's floor may
  /// not be **ember**: that colour means the microphone is open, and the floor
  /// is drawn even at silence, so leaving it warm would have the one reserved
  /// signal on screen over a closed microphone for the whole of a pause. Grey
  /// bars at the floor read as what they are: the meter, with nothing to say.
  var isLive: Bool = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: variant.barSpacing) {
      ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
        Capsule(style: .continuous)
          .fill(barColor)
          .frame(width: variant.barWidth, height: height)
      }
    }
    // Fixed frame: nothing the level does may change the size of the row this
    // sits in — the same rule the HUD's meter follows.
    .frame(width: variant.width, height: variant.maxBarHeight)
    .animation(RecordingMotion.meterAnimation(reduceMotion: reduceMotion), value: level)
    .accessibilityLabel("Microphone level")
  }

  private var heights: [CGFloat] {
    SessionMeterMetrics.barHeights(level: level, variant: variant)
  }

  private var barColor: Color {
    isLive ? CraftTokens.ember(colorScheme) : Color.secondary
  }
}

// MARK: - Session ring

/// The breathing ring's numbers. Pure, so "how far it breathes and how long it
/// takes" is asserted without waiting 2.6 seconds for a render.
enum SessionRingMetrics {
  /// One full inhale-exhale. Slow enough to read as breathing rather than as a
  /// pulse — a pulse is an alert, and nothing is wrong.
  static let cycle: TimeInterval = 2.6
  /// ~3.5%. Large enough to notice in peripheral vision, small enough that the
  /// ring never collides with what it encircles.
  static let scaleAmplitude: CGFloat = 0.035

  static let restOpacity: Double = 0.55
  static let peakOpacity: Double = 0.90

  /// `atPeak` is the *animated* end of the cycle; the view drives it to true on
  /// appear and lets `RecordingMotion.ringAnimation` autoreverse it forever.
  /// Under Reduce Motion the view never asks for the peak, so both values below
  /// collapse to their resting halves and the ring simply holds.
  static func scale(atPeak: Bool) -> CGFloat {
    atPeak ? 1 + scaleAmplitude : 1
  }

  static func opacity(atPeak: Bool) -> Double {
    atPeak ? peakOpacity : restOpacity
  }

  /// What the ring is doing at a given Reduce Motion setting, as one value —
  /// this is the pair the asymmetry test reads.
  static func breathes(reduceMotion: Bool) -> Bool { !reduceMotion }
}

/// The ember ring that says a session is running. Decoration, by construction:
/// it carries no state the owner needs and holds perfectly still under Reduce
/// Motion.
struct SessionRing: View {
  var diameter: CGFloat = 96
  var lineWidth: CGFloat = 2

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @State private var atPeak = false

  var body: some View {
    Circle()
      .fill(CraftTokens.emberWash(colorScheme))
      .overlay(
        Circle().strokeBorder(
          CraftTokens.ember(colorScheme).opacity(SessionRingMetrics.opacity(atPeak: atPeak)),
          lineWidth: lineWidth
        )
      )
      .frame(width: diameter, height: diameter)
      .scaleEffect(SessionRingMetrics.scale(atPeak: atPeak))
      .onAppear(perform: startBreathing)
      .accessibilityHidden(true)
  }

  private func startBreathing() {
    guard SessionRingMetrics.breathes(reduceMotion: reduceMotion) else { return }
    guard let animation = RecordingMotion.ringAnimation(reduceMotion: reduceMotion) else { return }
    withAnimation(animation) { atPeak = true }
  }
}

// MARK: - Session timer

/// The elapsed clock's type decisions, all of them arithmetic.
///
/// The one that needs writing down is the **step**: `mm:ss` is drawn at the
/// caller's size and `h:mm:ss` at 72% of it, and the change happens exactly
/// once, at the hour. It is deliberately not a fitted or auto-shrinking font —
/// those re-measure on every tick and the digits would breathe with the seconds.
/// The plate reserves the wider of the two forms up front, so the step costs no
/// reflow: the glyphs get smaller inside a box that never moves.
enum SessionTimerMetrics {
  /// 58 → 42 in the recording column.
  static let hourFontScale: CGFloat = 0.72

  enum Form: Equatable, CaseIterable {
    case minutesSeconds
    case hoursMinutesSeconds

    /// What the plate has to be able to hold for this form. `hh:mm:ss` rather
    /// than `h:mm:ss`: the step may happen only once, so a tenth hour must not
    /// be able to ask for a second one.
    var reservedCharacters: Int {
      switch self {
      case .minutesSeconds: return 5
      case .hoursMinutesSeconds: return 8
      }
    }
  }

  static func form(elapsed: TimeInterval) -> Form {
    wholeSeconds(elapsed) >= 3600 ? .hoursMinutesSeconds : .minutesSeconds
  }

  /// `59:59`, then `1:00:00`.
  static func text(elapsed: TimeInterval) -> String {
    let total = wholeSeconds(elapsed)
    let seconds = total % 60
    let minutes = (total / 60) % 60
    let hours = total / 3600
    switch form(elapsed: elapsed) {
    case .minutesSeconds:
      return String(format: "%02d:%02d", minutes, seconds)
    case .hoursMinutesSeconds:
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
  }

  /// The step function itself. Rounded, so the two sizes are whole points and
  /// the same at every call site.
  static func fontSize(base: CGFloat, elapsed: TimeInterval) -> CGFloat {
    fontSize(base: base, form: form(elapsed: elapsed))
  }

  static func fontSize(base: CGFloat, form: Form) -> CGFloat {
    switch form {
    case .minutesSeconds: return base
    case .hoursMinutesSeconds: return (base * hourFontScale).rounded()
    }
  }

  /// The width the timer reserves — the widest either form can ever need, and
  /// therefore **independent of `elapsed` by construction**. That is what makes
  /// "the plate keeps its width" a fact about the code rather than a hope about
  /// the metrics.
  static func plateWidth(base: CGFloat) -> CGFloat {
    Form.allCases
      .map { width(characters: $0.reservedCharacters, atSize: fontSize(base: base, form: $0)) }
      .reduce(0, max)
      .rounded(.up)
  }

  /// The height that same plate reserves — the widest form's line box, so it is
  /// **independent of `elapsed`** by exactly the construction `plateWidth` uses.
  ///
  /// The bar's height is derived from this (XIA-444: the bloom is the clock
  /// growing, so the card is as tall as the clock needs). It is the **line
  /// box**, which is what a laid-out `Text` occupies — deliberately not the ink.
  /// The session column measured the ink instead (`ringGlyphHeightRatio`, gone
  /// with the column), because monospaced digits have neither ascenders nor
  /// descenders and a *circle* drawn to the line box is a circle drawn around
  /// whitespace. A row that has to contain the digits owes the opposite number:
  /// clip the line box and the glyphs go with it.
  static func plateHeight(base: CGFloat) -> CGFloat {
    Form.allCases
      .map { height(atSize: fontSize(base: base, form: $0)) }
      .reduce(0, max)
      .rounded(.up)
  }

  static let weight: Font.Weight = .medium

  static func font(base: CGFloat, elapsed: TimeInterval) -> Font {
    .system(size: fontSize(base: base, elapsed: elapsed), weight: weight, design: .monospaced)
  }

  private static func wholeSeconds(_ elapsed: TimeInterval) -> Int {
    guard elapsed.isFinite, elapsed > 0 else { return 0 }
    return Int(elapsed)
  }

  /// SF Mono advances every glyph identically — the colon included — so one
  /// measurement times the character count is the exact string width.
  private static func width(characters: Int, atSize size: CGFloat) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
    return advance * CGFloat(characters) + 2
  }

  /// One line of digits, measured the same way — every glyph in this face has
  /// the same line box, so any of them answers for the string.
  private static func height(atSize size: CGFloat) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
    return ("0" as NSString).size(withAttributes: [.font: font]).height
  }
}

/// The elapsed clock: mono, tabular, and the single most legible thing on a
/// recording surface.
struct SessionTimer: View {
  let elapsed: TimeInterval
  /// The `mm:ss` size. The hour form derives from it — callers never pass two.
  var base: CGFloat = 58
  /// The ground-ink tier the digits take, or nil for `.primary`.
  ///
  /// The **receipt** hands it `.body`: it sits in the main window beside facts
  /// that come from `GroundInk`, and a clock in `labelColor` four points from
  /// facts in ground ink is one row drawn out of two colour systems. The
  /// recording cluster and the island keep `.primary` — the island's panel is
  /// forced `.darkAqua`, where `.primary` is exactly the white it wants.
  var tier: GroundInk.Tier?

  var body: some View {
    Text(SessionTimerMetrics.text(elapsed: elapsed))
      .font(SessionTimerMetrics.font(base: base, elapsed: elapsed))
      .monospacedDigit()
      .foregroundStyle(
        tier.map { AnyShapeStyle(GroundInkStyle(tier: $0)) }
          ?? AnyShapeStyle(HierarchicalShapeStyle.primary))
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      // Reserved once for the widest form, so crossing the hour re-sizes the
      // glyphs and moves nothing around them.
      .frame(width: SessionTimerMetrics.plateWidth(base: base))
      .accessibilityLabel("Elapsed time")
  }
}

// MARK: - Previews

#if DEBUG
private struct RecordingAccentGallery: View {
  var body: some View {
    CraftWashBackground()
      .overlay(
        VStack(spacing: CraftTokens.spacing32) {
          HStack(spacing: CraftTokens.spacing24) {
            SessionRing()
              .overlay(SessionMeter(level: 0.7, variant: .tall))
            VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
              SessionTimer(elapsed: 3599)
              SessionTimer(elapsed: 3600)
            }
          }
          HStack(spacing: CraftTokens.spacing12) {
            SessionRing(diameter: 20, lineWidth: 1.5)
            SessionMeter(level: 0.5, variant: .compact)
            SessionTimer(elapsed: 754, base: 15)
          }
          .padding(.horizontal, CraftTokens.spacing16)
          .padding(.vertical, CraftTokens.spacing8)
          .craftGlassPanel(in: Capsule())
        }
        .padding(CraftTokens.spacing32)
      )
      .frame(width: 640, height: 460)
  }
}

#Preview("recording accent – light") {
  RecordingAccentGallery().preferredColorScheme(.light)
}

#Preview("recording accent – dark") {
  RecordingAccentGallery().preferredColorScheme(.dark)
}

#Preview("meter – light") {
  CraftWashBackground()
    .overlay(
      HStack(spacing: CraftTokens.spacing32) {
        ForEach([0.0, 0.25, 0.6, 1.0], id: \.self) { level in
          SessionMeter(level: Float(level), variant: .tall)
        }
        SessionMeter(level: 0.6, variant: .compact)
      }
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 240)
    .preferredColorScheme(.light)
}

#Preview("meter – dark") {
  CraftWashBackground()
    .overlay(
      HStack(spacing: CraftTokens.spacing32) {
        ForEach([0.0, 0.25, 0.6, 1.0], id: \.self) { level in
          SessionMeter(level: Float(level), variant: .tall)
        }
        SessionMeter(level: 0.6, variant: .compact)
      }
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 240)
    .preferredColorScheme(.dark)
}

#Preview("ring – light") {
  CraftWashBackground()
    .overlay(
      HStack(spacing: CraftTokens.spacing24) {
        SessionRing()
        SessionRing(diameter: 44)
        SessionRing(diameter: 20, lineWidth: 1.5)
      }
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 240)
    .preferredColorScheme(.light)
}

#Preview("ring – dark") {
  CraftWashBackground()
    .overlay(
      HStack(spacing: CraftTokens.spacing24) {
        SessionRing()
        SessionRing(diameter: 44)
        SessionRing(diameter: 20, lineWidth: 1.5)
      }
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 240)
    .preferredColorScheme(.dark)
}

#Preview("timer – light") {
  CraftWashBackground()
    .overlay(
      VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
        SessionTimer(elapsed: 7)
        SessionTimer(elapsed: 3599)
        SessionTimer(elapsed: 3600)
        SessionTimer(elapsed: 45_296)
      }
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.light)
}

#Preview("timer – dark") {
  CraftWashBackground()
    .overlay(
      VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
        SessionTimer(elapsed: 7)
        SessionTimer(elapsed: 3599)
        SessionTimer(elapsed: 3600)
        SessionTimer(elapsed: 45_296)
      }
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.dark)
}
#endif
