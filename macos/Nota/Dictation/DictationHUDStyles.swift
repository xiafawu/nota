import AppKit
import SwiftUI

// MARK: - Shared surface

/// The HUD's material, shared by every style that is not the pill.
///
/// Same grammar as `DictationHUDContentView` and the review card: one dark
/// translucent fill, a hairline stroke to separate it from dark backgrounds, a
/// shadow that falls off inside a transparent margin (a window cannot draw
/// outside its own frame), and `colorScheme` forced dark in both system themes.
///
/// The pill deliberately keeps its own inline copy of this chrome rather than
/// adopting the modifier: it is the default style and the regression baseline,
/// and re-expressing its background through a shared abstraction is exactly the
/// kind of "identical refactor" that turns out not to be.
struct HUDSurface: ViewModifier {
  /// Continuous corner radius. The pill's capsule shape does not generalize —
  /// a 40pt bar would be a lozenge and a 200pt card a stadium.
  var cornerRadius: CGFloat

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(Color(white: 0.09).opacity(0.9))
      }
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
      }
      .environment(\.colorScheme, .dark)
      .shadow(color: .black.opacity(0.24), radius: 10, y: 3)
      .padding(DictationHUDContentView.shadowMargin)
  }
}

extension View {
  func hudSurface(cornerRadius: CGFloat) -> some View {
    modifier(HUDSurface(cornerRadius: cornerRadius))
  }
}

// MARK: - Compact level meter

/// The RMS meter as the bar and the prompter show it: shorter, thinner, and
/// without the pill's idle breathing, because both styles sit next to text that
/// is doing the talking.
///
/// A separate view from the pill's meter on purpose — sharing one would mean
/// editing `ListeningView`, and the pill's rendering is the baseline.
struct HUDCompactMeter: View {
  let level: Float
  var barCount: Int = 7
  var maxHeight: CGFloat = 16

  /// Center-weighted silhouette, same family as the pill's.
  private static let profile: [CGFloat] = [0.4, 0.65, 0.9, 1.0, 0.9, 0.65, 0.4]

  var body: some View {
    HStack(spacing: 2.5) {
      ForEach(0..<barCount, id: \.self) { i in
        Capsule()
          .fill(.primary.opacity(0.85))
          .frame(width: 2.5, height: height(for: i))
      }
    }
    // Fixed height frame: the meter's spring is the only SwiftUI animation on
    // these styles, and it must never be able to change a size the window
    // animation is also responsible for.
    .frame(height: maxHeight)
    .animation(.spring(response: 0.28, dampingFraction: 0.55), value: level)
  }

  private func height(for index: Int) -> CGFloat {
    let base: CGFloat = 3
    let shape = Self.profile[index % Self.profile.count]
    let wobble = 0.75 + 0.25 * sin(Double(index) * 1.7 + Double(level) * 21)
    let drive = CGFloat(level) * shape * CGFloat(wobble)
    return min(maxHeight, max(base, base + (maxHeight - base) * drive))
  }
}

/// The red dot that says "the microphone is open" on the bar and the prompter.
struct HUDMicDot: View {
  var diameter: CGFloat = 8

  var body: some View {
    Circle()
      .fill(Color.red)
      .frame(width: diameter, height: diameter)
  }
}

// MARK: - Bar metrics

/// Sizing for the bar style.
///
/// Every number here is a constant, and that is the whole point: the bar's one
/// promise is that it never changes size, so its content view can be asserted
/// to produce the same fitting size for every state and every draft length
/// without laying out a window.
enum HUDBarMetrics {
  static let width: CGFloat = 520
  static let height: CGFloat = 40

  /// The bar itself, excluding the transparent shadow margin.
  static var contentSize: CGSize { CGSize(width: width, height: height) }

  /// The window frame the bar needs: the bar plus its shadow margin on all
  /// sides.
  static var windowSize: CGSize {
    let margin = DictationHUDContentView.shadowMargin * 2
    return CGSize(width: width + margin, height: height + margin)
  }

  static let cornerRadius: CGFloat = 12
  static let horizontalPadding: CGFloat = 14
  /// Gap between the meter cluster and the text lane.
  static let clusterSpacing: CGFloat = 12
  static let fontSize: CGFloat = 13

  /// Fraction of the text lane's leading edge the fade mask consumes.
  ///
  /// The bar is tail-anchored — the newest words sit at the right edge and older
  /// ones travel left out of the lane. A hard clip at the left edge reads as
  /// text being chopped; the gradient makes it read as text leaving.
  static let fadeFraction: CGFloat = 0.14
}

// MARK: - Bar

/// The bar style: meter left, one tail-anchored line right, 520×40, always.
struct DictationHUDBarView: View {
  let state: HUDState
  var draft: HUDDraft = .empty

  var body: some View {
    HStack(spacing: HUDBarMetrics.clusterSpacing) {
      leading
      textLane
    }
    .padding(.horizontal, HUDBarMetrics.horizontalPadding)
    // Fixed, not fitted: this frame is what makes "never resizes" true rather
    // than merely likely. Nothing inside can widen or heighten the bar; long
    // text truncates into the lane instead.
    .frame(width: HUDBarMetrics.width, height: HUDBarMetrics.height)
    .hudSurface(cornerRadius: HUDBarMetrics.cornerRadius)
  }

  @ViewBuilder
  private var leading: some View {
    switch state {
    case .hidden, .listening:
      HStack(spacing: 8) {
        HUDMicDot()
        HUDCompactMeter(level: levelForState)
      }
    case .processing:
      HStack(spacing: 8) {
        ProgressView()
          .scaleEffect(0.5)
          .frame(width: 12, height: 12)
      }
    case .success:
      glyph("checkmark.circle.fill", .green)
    case .warning:
      glyph("exclamationmark.triangle.fill", .orange)
    case .error:
      glyph("xmark.circle.fill", .red)
    }
  }

  private func glyph(_ name: String, _ color: Color) -> some View {
    Image(systemName: name)
      .foregroundStyle(color)
      .font(.system(size: 13, weight: .medium))
  }

  private var levelForState: Float {
    if case .listening(let level) = state { return level }
    return 0
  }

  /// The line lives at the trailing edge and grows leftward under the fade.
  private var textLane: some View {
    Text(lineText)
      .font(.system(size: HUDBarMetrics.fontSize))
      .foregroundStyle(lineColor)
      .lineLimit(1)
      // Head truncation is what keeps the newest words on screen when the line
      // outruns the lane; the fade below hides the ellipsis it leaves behind.
      .truncationMode(.head)
      .frame(maxWidth: .infinity, alignment: .trailing)
      .mask(fadeMask)
  }

  private var fadeMask: some View {
    LinearGradient(
      stops: [
        .init(color: .clear, location: 0),
        .init(color: .black, location: HUDBarMetrics.fadeFraction),
        .init(color: .black, location: 1),
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
  }

  private var lineText: String {
    switch state {
    case .hidden:
      return ""
    case .listening:
      return draft.boundedTail ?? "Listening…"
    case .processing(let step):
      return step
    case .success(let snippet):
      return snippet.isEmpty ? "Inserted" : snippet
    case .warning(let message), .error(let message):
      return message
    }
  }

  private var lineColor: Color {
    switch state {
    case .error: return .red.opacity(0.95)
    case .warning: return .orange.opacity(0.95)
    case .listening where draft.boundedTail == nil: return .primary.opacity(0.45)
    default: return .primary.opacity(0.85)
    }
  }
}

// MARK: - Prompter metrics

/// The head-trimmed halves of the session the prompter measures and draws.
typealias HUDPrompterWindow = (finalized: String, volatileTail: String)

/// Sizing and growth math for the prompter style.
///
/// Pure and AppKit-free apart from the font metric, so the cap — the one rule
/// that keeps a HUD hanging under the focused window from walking up into it —
/// can be asserted arithmetically.
enum HUDPrompterMetrics {
  static let width: CGFloat = 600
  static let cornerRadius: CGFloat = 16
  static let horizontalPadding: CGFloat = 16
  static let verticalPadding: CGFloat = 12
  /// Gap between the header row and the body.
  static let headerSpacing: CGFloat = 8
  static let headerHeight: CGFloat = 18
  static let bodyFontSize: CGFloat = 14

  /// Body lines shown before the text starts scrolling under its own top edge.
  static let minLines = 3
  static let maxLines = 6

  /// Height of one body line, from the real font so the cap corresponds to
  /// lines the user can actually count.
  static var lineHeight: CGFloat {
    let font = NSFont.systemFont(ofSize: bodyFontSize)
    return ceil(font.ascender - font.descender + font.leading)
  }

  /// Width available to body text.
  static var bodyWidth: CGFloat { width - horizontalPadding * 2 }

  /// `lines`, clamped into the range the card is allowed to show.
  ///
  /// Both ends matter. Below the floor the card would flicker between one and
  /// three lines as the first sentence lands; above the ceiling it would keep
  /// growing downward until it ran off the screen.
  static func clampedLineCount(_ lines: Int) -> Int {
    min(maxLines, max(minLines, lines))
  }

  /// Visible height of the body for a text that needs `lines` lines.
  static func bodyHeight(lineCount lines: Int) -> CGFloat {
    CGFloat(clampedLineCount(lines)) * lineHeight
  }

  /// Height of the whole card (excluding the transparent shadow margin).
  static func cardHeight(lineCount lines: Int) -> CGFloat {
    verticalPadding * 2 + headerHeight + headerSpacing + bodyHeight(lineCount: lines)
  }

  /// Window height for `lines`: the card plus its shadow margin.
  static func windowHeight(lineCount lines: Int) -> CGFloat {
    cardHeight(lineCount: lines) + DictationHUDContentView.shadowMargin * 2
  }

  // MARK: The measured window

  /// Characters of the session the card measures and draws.
  ///
  /// The card shows `maxLines` lines and clips everything above them, but the
  /// view used to measure (`boundingRect`) and lay out the *whole* session on
  /// the main actor on every HUD tick — and `DictationHUDController.update()`
  /// runs on every `objectWillChange` plus a 66 ms RMS tick, against a string
  /// that grows for as long as the user keeps talking. That is an O(session
  /// length) cost with no upper bound; this is the bound.
  ///
  /// Sized well past what `maxLines` lines can hold even at the narrowest
  /// glyph widths the body font has, so no character that could be visible is
  /// outside the window and the *clamped* line count — the only thing the card
  /// height depends on — is the same as it would be for the full text.
  /// `HUDPrompterWindowTests` asserts both ends of that.
  ///
  /// What is left per tick is a character count and a copy of the window: two
  /// orders of magnitude under a text layout, and the layout itself no longer
  /// grows at all.
  static let windowBudget = 1800

  /// How far the text may overrun `windowBudget` before the window's head moves.
  ///
  /// The head is quantized rather than sliding. Greedy wrapping starts at
  /// whatever character the window begins with, so a head that advanced with
  /// every syllable would re-wrap the visible lines on every tick; quantized,
  /// the body re-wraps at most once per `windowStep` characters and is
  /// otherwise laid out exactly as it was on the previous tick.
  static let windowStep = 600

  /// The `(finalized, volatileTail)` pair the card actually measures and draws.
  ///
  /// Head-trimmed only: the cut lands in text that is already clipped above the
  /// top edge, and the newest words — the ones pinned to the bottom edge — are
  /// never touched.
  static func windowed(
    finalized: String,
    volatileTail: String
  ) -> HUDPrompterWindow {
    let overflow = finalized.count + volatileTail.count - windowBudget
    guard overflow > 0 else { return (finalized, volatileTail) }
    let cut = (overflow / windowStep) * windowStep
    guard cut > 0 else { return (finalized, volatileTail) }
    guard cut < finalized.count else {
      return ("", String(volatileTail.dropFirst(cut - finalized.count)))
    }
    return (String(finalized.dropFirst(cut)), volatileTail)
  }

  /// The two runs the card draws: finalized text at full opacity, then the
  /// volatile tail dimmed.
  ///
  /// The separator rides on the finalized run (a space carries no ink, so which
  /// run owns it is invisible) because concatenating the runs has to reproduce
  /// the string the card measured. `Text(a) + Text(" ") + Text(b)` does not:
  /// Apple's volatile results sometimes arrive with their leading space already
  /// attached, and `StreamingDelivery.joined` — what the measurement runs on —
  /// does not add a second one.
  static func runs(
    finalized: String,
    volatileTail: String
  ) -> HUDPrompterWindow {
    (
      finalized + StreamingDelivery.joiningSeparator(finalized, volatileTail),
      volatileTail
    )
  }

  /// How many lines `text` wraps to at `bodyWidth`.
  ///
  /// Unclamped — callers clamp — so the caller can tell "three lines" from
  /// "thirty, so scroll".
  static func lineCount(for text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    let font = NSFont.systemFont(ofSize: bodyFontSize)
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let bounds = attributed.boundingRect(
      with: CGSize(width: bodyWidth, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return max(1, Int(ceil(bounds.height / lineHeight)))
  }
}

// MARK: - Prompter

/// The prompter style: a 600pt card carrying the whole session.
///
/// Growth is the window's job. This view reports a height derived from the
/// text's line count, clamped to the cap, and `DictationHUDPanel.update`
/// animates the window frame to it — the single animation authority. Nothing
/// here animates anything that can change a size.
///
/// Past the cap the body **does not scroll**, in the `ScrollView` sense: the
/// full text is laid out inside a clipped, bottom-aligned frame, so the newest
/// line is pinned to the bottom edge and older lines slide out of the top. That
/// is auto-following by construction rather than by a scroll animation racing
/// the window's — and the panel ignores mouse events, so there was never a user
/// scroll to preserve.
struct DictationHUDPrompterView: View {
  let state: HUDState
  var draft: HUDDraft = .empty

  var body: some View {
    // Bounded once, here, and used for both the measurement and the drawing:
    // the two must agree, and neither may cost more as the session runs on.
    let window = HUDPrompterMetrics.windowed(
      finalized: draft.finalized,
      volatileTail: draft.volatileTail
    )

    VStack(alignment: .leading, spacing: HUDPrompterMetrics.headerSpacing) {
      header
      bodyBlock(window: window, width: HUDPrompterMetrics.bodyWidth)
    }
    .padding(.horizontal, HUDPrompterMetrics.horizontalPadding)
    .padding(.vertical, HUDPrompterMetrics.verticalPadding)
    .frame(width: HUDPrompterMetrics.width, alignment: .leading)
    .hudSurface(cornerRadius: HUDPrompterMetrics.cornerRadius)
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      HUDMicDot(diameter: 7)
      HUDCompactMeter(level: levelForState, barCount: 5, maxHeight: 14)
      Text(headline)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.primary.opacity(0.8))
        .lineLimit(1)
      Spacer(minLength: 8)
      Text(wordCountLabel)
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.primary.opacity(0.45))
        .lineLimit(1)
    }
    .frame(height: HUDPrompterMetrics.headerHeight)
  }

  private var headline: String {
    switch state {
    case .hidden, .listening: return "Dictating"
    case .processing(let step): return step
    case .success: return "Inserted"
    case .warning: return "Warning"
    case .error: return "Failed"
    }
  }

  private var wordCountLabel: String {
    let count = draft.wordCount
    return count == 1 ? "1 word" : "\(count) words"
  }

  private var levelForState: Float {
    if case .listening(let level) = state { return level }
    return 0
  }

  // MARK: Body

  @ViewBuilder
  private func bodyBlock(window: HUDPrompterWindow, width: CGFloat) -> some View {
    let measured = bodyText(window: window)
    let visibleHeight = HUDPrompterMetrics.bodyHeight(
      lineCount: HUDPrompterMetrics.lineCount(for: measured)
    )

    text(window: window, measured: measured)
      .font(.system(size: HUDPrompterMetrics.bodyFontSize))
      .lineSpacing(0)
      .multilineTextAlignment(.leading)
      .frame(width: width, alignment: .topLeading)
      .fixedSize(horizontal: false, vertical: true)
      // Bottom-aligned inside a shorter frame: anything past the cap overflows
      // upward and is clipped, which pins the newest words to the bottom edge
      // with no scroll position to keep in sync.
      .frame(width: width, height: visibleHeight, alignment: .bottomLeading)
      .clipped()
  }

  /// Finalized text at full opacity, the volatile tail dimmed — the card's one
  /// piece of information beyond the words themselves: which of them the
  /// recognizer has committed to.
  ///
  /// Drawn from `HUDPrompterMetrics.runs`, so the glyphs on screen concatenate
  /// to exactly the `measured` string the card sized itself from.
  private func text(window: HUDPrompterWindow, measured: String) -> Text {
    guard case .listening = state else {
      return Text(measured).foregroundStyle(.primary.opacity(0.85))
    }
    let runs = HUDPrompterMetrics.runs(
      finalized: window.finalized,
      volatileTail: window.volatileTail
    )
    let finalized = Text(runs.finalized).foregroundStyle(.primary.opacity(0.92))
    guard !runs.volatileTail.isEmpty else { return finalized }
    let tail = Text(runs.volatileTail).foregroundStyle(Color.white.opacity(0.55))
    guard !runs.finalized.isEmpty else { return tail }
    return finalized + tail
  }

  private func bodyText(window: HUDPrompterWindow) -> String {
    switch state {
    case .hidden, .listening:
      return StreamingDelivery.joined(window.finalized, window.volatileTail)
    case .processing:
      let text = StreamingDelivery.joined(window.finalized, window.volatileTail)
      return text.isEmpty ? "…" : text
    case .success(let snippet):
      return snippet
    case .warning(let message), .error(let message):
      return message
    }
  }
}

// MARK: - Growth room

extension HUDStyle {
  /// The tallest this style's card can become, or nil when its height is not
  /// the panel's to reserve.
  ///
  /// `DictationHUDPanel.reposition` holds this much room below the panel so a
  /// later growth never reaches the bottom of the screen. Without it, a card
  /// anchored under a window that already sits on the screen's bottom edge
  /// grows downward, is shoved back up by `DictationHUDPanel.clamped`, and its
  /// top edge — the one thing "grow DOWN" pins — walks into the window it hangs
  /// under.
  ///
  /// The bar cannot grow at all, and the pill's positioning is the regression
  /// baseline this change is not allowed to move: both return nil and go on
  /// being placed by their current height.
  var reservedCardHeight: CGFloat? {
    switch self {
    case .pill, .bar:
      return nil
    case .prompter:
      return HUDPrompterMetrics.cardHeight(lineCount: HUDPrompterMetrics.maxLines)
    }
  }
}

// MARK: - Root

/// One entry point for all three styles, so the panel holds a single hosting
/// view whatever the user picked.
///
/// `.pill` forwards straight to `DictationHUDContentView` with the same bounded
/// tail it has always been handed — the style switch adds no branch to the
/// default path.
struct DictationHUDRootView: View {
  var style: HUDStyle = .pill
  let state: HUDState
  var draft: HUDDraft = .empty

  var body: some View {
    if case .hidden = state {
      Color.clear.frame(width: 0, height: 0)
    } else {
      switch style {
      case .pill:
        DictationHUDContentView(state: state, roughDraft: draft.boundedTail)
      case .bar:
        DictationHUDBarView(state: state, draft: draft)
      case .prompter:
        DictationHUDPrompterView(state: state, draft: draft)
      }
    }
  }
}
