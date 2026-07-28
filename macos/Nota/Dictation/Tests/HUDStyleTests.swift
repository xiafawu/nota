import AppKit
import SwiftUI
import XCTest

@testable import Nota

// MARK: - Setting

/// `hudStyle` is a new key with no migration, so the only thing that can go
/// wrong is the thing `DictationSettings.init(from:)` exists to prevent: a
/// payload without it, or with a value this build does not know, taking the
/// user's other preferences down with it.
final class HUDStyleSettingTests: XCTestCase {
  override func tearDown() {
    DictationSettingsStore.reset()
    super.tearDown()
  }

  func testDefaultIsPill() {
    XCTAssertEqual(DictationSettings().hudStyle, .pill)
  }

  func testMissingKeyDecodesToPillWithoutDisturbingOtherFields() throws {
    // A payload written by a build that predates the setting: every other key
    // present, `hudStyle` absent.
    let json = """
      {"engine":"apple","activation":"toggle","polishEnabled":true,
       "showHUD":true,"deliveryMode":"review",
       "trigger":{"kind":"fnGlobe"}}
      """
    let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.hudStyle, .pill)
    XCTAssertEqual(settings.activation, .toggle)
    XCTAssertEqual(settings.polishEnabled, true)
    XCTAssertEqual(settings.deliveryMode, .review)
  }

  func testUnknownValueDecodesToPill() throws {
    let json = """
      {"engine":"apple","activation":"hold","polishEnabled":false,
       "showHUD":true,"deliveryMode":"immediate","hudStyle":"teleprompter",
       "trigger":{"kind":"fnGlobe"}}
      """
    let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.hudStyle, .pill)
    // The bad value costs only itself.
    XCTAssertEqual(settings.engine, .apple)
    XCTAssertEqual(settings.showHUD, true)
  }

  func testWrongTypeDecodesToPill() throws {
    let json = """
      {"showHUD":true,"hudStyle":17,"trigger":{"kind":"fnGlobe"}}
      """
    let settings = try JSONDecoder().decode(DictationSettings.self, from: Data(json.utf8))
    XCTAssertEqual(settings.hudStyle, .pill)
  }

  func testEveryStyleRoundTripsThroughJSON() throws {
    for style in HUDStyle.allCases {
      var settings = DictationSettings()
      settings.hudStyle = style
      let data = try JSONEncoder().encode(settings)
      let decoded = try JSONDecoder().decode(DictationSettings.self, from: data)
      XCTAssertEqual(decoded.hudStyle, style)
      XCTAssertEqual(decoded, settings)
    }
  }

  func testEveryStyleRoundTripsThroughTheStore() {
    for style in HUDStyle.allCases {
      var settings = DictationSettingsStore.load()
      settings.hudStyle = style
      DictationSettingsStore.save(settings)
      XCTAssertEqual(DictationSettingsStore.load().hudStyle, style)
    }
  }

  /// The bar's fixed size is a property of the style, not of a view: the panel
  /// consults it to decide whether a frame change may be animated at all.
  func testOnlyTheBarRefusesGrowthAnimation() {
    XCTAssertFalse(HUDStyle.bar.animatesGrowth)
    XCTAssertTrue(HUDStyle.pill.animatesGrowth)
    XCTAssertTrue(HUDStyle.prompter.animatesGrowth)
  }
}

// MARK: - Draft feed

/// The split feed: one bounded line for the pill and the bar, two full-length
/// strings for the prompter.
final class HUDDraftTests: XCTestCase {
  func testEmptyDraftShowsNothing() {
    XCTAssertTrue(HUDDraft.empty.isEmpty)
    XCTAssertNil(HUDDraft.empty.boundedTail)
    XCTAssertEqual(HUDDraft.empty.fullText, "")
    XCTAssertEqual(HUDDraft.empty.wordCount, 0)
  }

  /// The pill's line must be byte-identical to what it was handed before the
  /// other styles existed — `roughDraftTail` over the volatile tail alone.
  func testBoundedTailMatchesThePreExistingPillLine() {
    let volatile = "ship the gency to rust rewrite"
    let draft = HUDDraft(finalized: "Earlier finalized sentence.", volatileTail: volatile)
    XCTAssertEqual(draft.boundedTail, StreamingDelivery.roughDraftTail(volatile))
    XCTAssertFalse(draft.boundedTail?.contains("Earlier") ?? true)
  }

  func testBoundedTailIsClampedButFinalizedAndVolatileAreNot() throws {
    let volatile = (1...200).map { "word\($0)" }.joined(separator: " ")
    let finalized = (1...400).map { "prior\($0)" }.joined(separator: " ")
    let draft = HUDDraft(finalized: finalized, volatileTail: volatile)

    let tail = try XCTUnwrap(draft.boundedTail)
    // The clamp plus its leading ellipsis, and nothing more.
    XCTAssertLessThanOrEqual(tail.count, StreamingDelivery.roughDraftLimit + 1)
    XCTAssertTrue(tail.hasSuffix("word200"))

    // The prompter's halves are untouched.
    XCTAssertEqual(draft.finalized, finalized)
    XCTAssertEqual(draft.volatileTail, volatile)
    XCTAssertTrue(draft.fullText.hasPrefix("prior1 "))
    XCTAssertTrue(draft.fullText.hasSuffix("word200"))
    XCTAssertGreaterThan(draft.fullText.count, StreamingDelivery.roughDraftLimit)
  }

  func testFullTextJoinsWithExactlyOneSpace() {
    XCTAssertEqual(HUDDraft(finalized: "Hello.", volatileTail: "world").fullText, "Hello. world")
    XCTAssertEqual(HUDDraft(finalized: "Hello. ", volatileTail: "world").fullText, "Hello. world")
    XCTAssertEqual(HUDDraft(finalized: "", volatileTail: "world").fullText, "world")
    XCTAssertEqual(HUDDraft(finalized: "Hello.", volatileTail: "").fullText, "Hello.")
  }

  func testWordCountSpansBothHalves() {
    XCTAssertEqual(HUDDraft(finalized: "one two three", volatileTail: "four").wordCount, 4)
    XCTAssertEqual(HUDDraft(finalized: "  ", volatileTail: " one  two ").wordCount, 2)
  }

  /// A draft that has only just finalized: the volatile tail is cleared by the
  /// controller at that moment, so the pill's line goes empty while the
  /// prompter keeps the whole session.
  func testFinalizationEmptiesTheBoundedLineButNotThePromptersText() {
    let draft = HUDDraft(finalized: "Ship the genc2rust rewrite.", volatileTail: "")
    XCTAssertNil(draft.boundedTail)
    XCTAssertEqual(draft.fullText, "Ship the genc2rust rewrite.")
    XCTAssertFalse(draft.isEmpty)
  }
}

// MARK: - Pill baseline

/// The pill is the default style and the thing this change is not allowed to
/// move. Routing it through `DictationHUDRootView` must produce the same view
/// `DictationHUDContentView` produced on its own, fed the same line the
/// controller fed it before the split existed.
@MainActor
final class HUDPillBaselineTests: XCTestCase {
  func testRoutingThroughTheRootViewLaysOutIdenticallyToTheContentViewAlone() {
    for volatileTail in Self.drafts {
      let draft = HUDDraft(finalized: "a finalized sentence.", volatileTail: volatileTail)
      let routed = Self.fittingSize(
        NSHostingView(
          rootView: DictationHUDRootView(
            style: .pill, state: .listening(level: 0.4), draft: draft
          )
        )
      )
      // The exact call `DictationHUDController` made before the split:
      // `roughDraftTail` over the volatile tail, and nothing else.
      let direct = Self.fittingSize(
        NSHostingView(
          rootView: DictationHUDContentView(
            state: .listening(level: 0.4),
            roughDraft: StreamingDelivery.roughDraftTail(volatileTail)
          )
        )
      )
      XCTAssertEqual(routed.width, direct.width, accuracy: 0.5, "draft: \(volatileTail)")
      XCTAssertEqual(routed.height, direct.height, accuracy: 0.5, "draft: \(volatileTail)")
    }
  }

  /// The finalized half is invisible to the pill: it renders the volatile tail
  /// and nothing else, exactly as before.
  func testTheFinalizedHalfDoesNotReachThePill() {
    let withHistory = HUDDraft(
      finalized: (1...300).map { "prior\($0)" }.joined(separator: " "),
      volatileTail: "hello"
    )
    let withoutHistory = HUDDraft(finalized: "", volatileTail: "hello")
    XCTAssertEqual(withHistory.boundedTail, withoutHistory.boundedTail)
    XCTAssertEqual(
      Self.fittingSize(
        NSHostingView(
          rootView: DictationHUDRootView(
            style: .pill, state: .listening(level: 0.4), draft: withHistory
          )
        )
      ),
      Self.fittingSize(
        NSHostingView(
          rootView: DictationHUDRootView(
            style: .pill, state: .listening(level: 0.4), draft: withoutHistory
          )
        )
      )
    )
  }

  /// The pill still animates its growth; only the bar opts out.
  func testPillStillGrowsWhenTheDraftStarts() {
    let meterOnly = Self.fittingSize(
      NSHostingView(
        rootView: DictationHUDRootView(
          style: .pill, state: .listening(level: 0.4), draft: .empty
        )
      )
    )
    let withDraft = Self.fittingSize(
      NSHostingView(
        rootView: DictationHUDRootView(
          style: .pill,
          state: .listening(level: 0.4),
          draft: HUDDraft(volatileTail: "hello")
        )
      )
    )
    XCTAssertGreaterThan(withDraft.width, meterOnly.width)
  }

  private static let drafts: [String] = [
    "",
    "hello",
    (1...20).map { "word\($0)" }.joined(separator: " "),
    (1...60).map { "word\($0)" }.joined(separator: " "),
  ]

  private static func fittingSize(_ view: NSHostingView<some View>) -> CGSize {
    view.layoutSubtreeIfNeeded()
    return view.fittingSize
  }
}

// MARK: - Bar sizing

/// The bar's one promise: it never changes size. Not "rarely", not "only when
/// the text is short" — the fitting size is the same constant for every state
/// and every draft the recognizer can produce.
@MainActor
final class HUDBarSizingTests: XCTestCase {
  func testMetricsAreTheDeclaredFixedSize() {
    XCTAssertEqual(HUDBarMetrics.contentSize, CGSize(width: 520, height: 40))
    let margin = DictationHUDContentView.shadowMargin * 2
    XCTAssertEqual(HUDBarMetrics.windowSize.width, 520 + margin)
    XCTAssertEqual(HUDBarMetrics.windowSize.height, 40 + margin)
  }

  func testFittingSizeIsTheFixedSizePlusTheShadowMargin() {
    let size = Self.fittingSize(state: .listening(level: 0.4), draft: .empty)
    XCTAssertEqual(size.width, HUDBarMetrics.windowSize.width, accuracy: 0.5)
    XCTAssertEqual(size.height, HUDBarMetrics.windowSize.height, accuracy: 0.5)
  }

  func testFittingSizeNeverMovesAsTheDraftGrows() {
    let sizes = Self.growingDrafts.map { draft in
      Self.fittingSize(
        state: .listening(level: 0.5),
        draft: HUDDraft(finalized: draft, volatileTail: draft)
      )
    }
    XCTAssertFalse(sizes.contains(.zero), "hosting view produced no layout")
    XCTAssertEqual(Set(sizes.map(\.width)).count, 1, "bar width moved: \(sizes)")
    XCTAssertEqual(Set(sizes.map(\.height)).count, 1, "bar height moved: \(sizes)")
  }

  func testFittingSizeNeverMovesAcrossStates() {
    let states: [HUDState] = [
      .listening(level: 0),
      .listening(level: 1),
      .processing(step: "Polishing…"),
      .success(snippet: "ship the genc2rust rewrite"),
      .warning(message: String(repeating: "polish failed. ", count: 12)),
      .error(message: "Microphone capture could not start: no input device"),
    ]
    let sizes = states.map { Self.fittingSize(state: $0, draft: .empty) }
    XCTAssertEqual(Set(sizes.map(\.width)).count, 1, "bar width moved by state: \(sizes)")
    XCTAssertEqual(Set(sizes.map(\.height)).count, 1, "bar height moved by state: \(sizes)")
  }

  private static let growingDrafts: [String] = {
    let words = (1...80).map { "word\($0)" }
    return stride(from: 1, through: 80, by: 7).map { words.prefix($0).joined(separator: " ") }
  }()

  private static func fittingSize(state: HUDState, draft: HUDDraft) -> CGSize {
    let view = NSHostingView(
      rootView: DictationHUDRootView(style: .bar, state: state, draft: draft)
    )
    view.layoutSubtreeIfNeeded()
    return view.fittingSize
  }
}

// MARK: - Prompter sizing

/// The prompter grows downward and stops. The cap is what keeps a HUD that
/// hangs *under* the focused window from walking up into it once the session
/// runs long — the same rule the pill's two-line draft limit encodes.
@MainActor
final class HUDPrompterSizingTests: XCTestCase {
  func testLineCountIsClampedAtBothEnds() {
    XCTAssertEqual(HUDPrompterMetrics.clampedLineCount(0), HUDPrompterMetrics.minLines)
    XCTAssertEqual(HUDPrompterMetrics.clampedLineCount(1), HUDPrompterMetrics.minLines)
    XCTAssertEqual(HUDPrompterMetrics.clampedLineCount(3), 3)
    XCTAssertEqual(HUDPrompterMetrics.clampedLineCount(5), 5)
    XCTAssertEqual(HUDPrompterMetrics.clampedLineCount(6), HUDPrompterMetrics.maxLines)
    XCTAssertEqual(HUDPrompterMetrics.clampedLineCount(600), HUDPrompterMetrics.maxLines)
  }

  func testCardHeightIsMonotonicAndFlatOutsideTheRange() {
    let heights = (0...12).map { HUDPrompterMetrics.cardHeight(lineCount: $0) }
    for (a, b) in zip(heights, heights.dropFirst()) {
      XCTAssertLessThanOrEqual(a, b, "card height went backwards: \(heights)")
    }
    // Flat below the floor…
    XCTAssertEqual(heights[0], heights[HUDPrompterMetrics.minLines])
    // …and flat above the cap, forever.
    XCTAssertEqual(heights[HUDPrompterMetrics.maxLines], heights[12])
  }

  func testCardGrowsByExactlyOneLineHeightPerLineInsideTheRange() {
    let three = HUDPrompterMetrics.cardHeight(lineCount: 3)
    let four = HUDPrompterMetrics.cardHeight(lineCount: 4)
    XCTAssertEqual(four - three, HUDPrompterMetrics.lineHeight, accuracy: 0.01)
  }

  func testCapIsThreeLineHeightsAboveTheFloor() {
    let floor = HUDPrompterMetrics.cardHeight(lineCount: HUDPrompterMetrics.minLines)
    let cap = HUDPrompterMetrics.cardHeight(lineCount: HUDPrompterMetrics.maxLines)
    let span = CGFloat(HUDPrompterMetrics.maxLines - HUDPrompterMetrics.minLines)
    XCTAssertEqual(cap - floor, span * HUDPrompterMetrics.lineHeight, accuracy: 0.01)
  }

  func testMeasuredLineCountGrowsWithTheText() {
    let short = HUDPrompterMetrics.lineCount(for: "hello")
    let long = HUDPrompterMetrics.lineCount(
      for: (1...300).map { "word\($0)" }.joined(separator: " ")
    )
    XCTAssertEqual(HUDPrompterMetrics.lineCount(for: ""), 0)
    XCTAssertEqual(short, 1)
    XCTAssertGreaterThan(long, HUDPrompterMetrics.maxLines)
  }

  // MARK: Laid out

  func testCardIsSixHundredWidePlusTheShadowMargin() {
    let width = Self.fittingSize(draft: HUDDraft(finalized: "hello", volatileTail: "")).width
    let expected = HUDPrompterMetrics.width + DictationHUDContentView.shadowMargin * 2
    XCTAssertEqual(width, expected, accuracy: 0.5)
  }

  func testWidthNeverMovesHoweverLongTheSessionRuns() {
    let widths = Self.growingTexts.map { Self.fittingSize(draft: HUDDraft(finalized: $0)).width }
    XCTAssertFalse(widths.contains(0), "hosting view produced no layout")
    XCTAssertEqual(Set(widths).count, 1, "prompter width moved: \(widths)")
  }

  func testHeightGrowsWithTheTextAndStopsAtTheCap() {
    let heights = Self.growingTexts.map { Self.fittingSize(draft: HUDDraft(finalized: $0)).height }
    for (a, b) in zip(heights, heights.dropFirst()) {
      XCTAssertLessThanOrEqual(a, b, "prompter height went backwards: \(heights)")
    }
    let cap = HUDPrompterMetrics.windowHeight(lineCount: HUDPrompterMetrics.maxLines)
    for height in heights {
      XCTAssertLessThanOrEqual(height, cap + 0.5, "prompter grew past its cap: \(heights)")
    }
    // And it does actually grow: a one-word session and a hundred-line one are
    // not the same card.
    XCTAssertGreaterThan(heights.last ?? 0, heights.first ?? 0)
  }

  func testFloorHoldsForAOneWordSession() {
    let height = Self.fittingSize(draft: HUDDraft(finalized: "hello")).height
    let floor = HUDPrompterMetrics.windowHeight(lineCount: HUDPrompterMetrics.minLines)
    XCTAssertEqual(height, floor, accuracy: 0.5)
  }

  /// Everything past the cap is clipped rather than laid out taller, so a
  /// session that never stops talking cannot push the card up into the window
  /// it hangs under.
  func testAVeryLongSessionIsExactlyTheCappedCard() {
    let text = (1...2000).map { "word\($0)" }.joined(separator: " ")
    let height = Self.fittingSize(draft: HUDDraft(finalized: text)).height
    let cap = HUDPrompterMetrics.windowHeight(lineCount: HUDPrompterMetrics.maxLines)
    XCTAssertEqual(height, cap, accuracy: 0.5)
  }

  private static let growingTexts: [String] = {
    let words = (1...400).map { "word\($0)" }
    return [1, 4, 8, 16, 32, 64, 128, 400].map { words.prefix($0).joined(separator: " ") }
  }()

  private static func fittingSize(draft: HUDDraft) -> CGSize {
    let view = NSHostingView(
      rootView: DictationHUDRootView(style: .prompter, state: .listening(level: 0.3), draft: draft)
    )
    view.layoutSubtreeIfNeeded()
    return view.fittingSize
  }
}
