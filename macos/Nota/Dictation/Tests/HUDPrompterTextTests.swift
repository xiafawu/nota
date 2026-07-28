import AppKit
import SwiftUI
import XCTest

@testable import Nota

// MARK: - Prompter runs

/// The prompter measures one string and draws two `Text` runs. They have to be
/// the same string.
final class HUDPrompterRunTests: XCTestCase {
  /// Apple's volatile results sometimes arrive with their leading space already
  /// attached — the case `StreamingDelivery.joined` exists to absorb. The card
  /// used to size itself from `joined` (one space) and draw
  /// `finalized + Text(" ") + tail` (two).
  func testRunsConcatenateToTheStringTheCardMeasured() {
    for (finalized, tail) in Self.pairs {
      let runs = HUDPrompterMetrics.runs(finalized: finalized, volatileTail: tail)
      XCTAssertEqual(
        runs.finalized + runs.volatileTail,
        StreamingDelivery.joined(finalized, tail),
        "drawn text diverged from measured text for (\(finalized), \(tail))"
      )
    }
  }

  func testALeadingSpaceOnTheVolatileTailIsNotDoubled() {
    let runs = HUDPrompterMetrics.runs(
      finalized: "Ship the rewrite.", volatileTail: " before friday"
    )
    XCTAssertEqual(runs.finalized, "Ship the rewrite.")
    XCTAssertFalse((runs.finalized + runs.volatileTail).contains("  "))
  }

  /// Two drafts whose joined text is the *same string* must draw the same
  /// glyphs. The unconditional separator broke exactly this.
  func testDraftsThatMeasureTheSameDrawTheSame() {
    let leadingSpace = HUDPrompterMetrics.runs(finalized: "a", volatileTail: " b")
    let trailingSpace = HUDPrompterMetrics.runs(finalized: "a ", volatileTail: "b")
    XCTAssertEqual(
      leadingSpace.finalized + leadingSpace.volatileTail,
      trailingSpace.finalized + trailingSpace.volatileTail
    )
  }

  /// The separator helper and the joiner it was split out of cannot drift.
  func testJoinedIsExactlyExistingPlusSeparatorPlusAddition() {
    for (existing, addition) in Self.pairs {
      XCTAssertEqual(
        existing + StreamingDelivery.joiningSeparator(existing, addition) + addition,
        StreamingDelivery.joined(existing, addition)
      )
    }
  }

  private static let pairs: [(String, String)] = [
    ("Ship the rewrite.", " before friday"),
    ("Ship the rewrite.", "before friday"),
    ("Ship the rewrite. ", "before friday"),
    ("Ship the rewrite. ", " before friday"),
    ("Ship the rewrite.\n", "before friday"),
    ("", "before friday"),
    ("", " before friday"),
    ("Ship the rewrite.", ""),
    ("", ""),
  ]
}

// MARK: - Prompter window

/// The card shows six lines and clips the rest, so it may only measure and lay
/// out a bounded window of the session — `DictationHUDController.update()` runs
/// on every 66 ms RMS tick and the session's text grows for as long as the user
/// keeps talking.
final class HUDPrompterWindowTests: XCTestCase {
  func testAShortSessionIsNotTrimmedAtAll() {
    let window = HUDPrompterMetrics.windowed(
      finalized: "Ship the rewrite.", volatileTail: " before friday"
    )
    XCTAssertEqual(window.finalized, "Ship the rewrite.")
    XCTAssertEqual(window.volatileTail, " before friday")
  }

  func testTheWindowIsBoundedHoweverLongTheSessionRuns() {
    for text in Self.growingSessions {
      let window = HUDPrompterMetrics.windowed(finalized: text, volatileTail: "and so on")
      let kept = window.finalized.count + window.volatileTail.count
      XCTAssertLessThan(
        kept,
        HUDPrompterMetrics.windowBudget + HUDPrompterMetrics.windowStep,
        "window grew with the session: \(kept) characters"
      )
    }
  }

  /// Head-trimmed only: the newest words — the ones pinned to the bottom edge —
  /// are always in the window.
  func testTheWindowKeepsTheNewestText() {
    let text = (1...4000).map { "word\($0)" }.joined(separator: " ")
    let window = HUDPrompterMetrics.windowed(finalized: text, volatileTail: "still talking")
    XCTAssertTrue(window.finalized.hasSuffix("word4000"))
    XCTAssertEqual(window.volatileTail, "still talking")
    XCTAssertTrue(text.hasSuffix(window.finalized))
  }

  /// The whole justification for trimming: the card's height depends only on
  /// the *clamped* line count, and the window is wide enough that the clamped
  /// count is the same one the full text would have produced.
  func testTheClampedLineCountSurvivesTheTrim() {
    for text in Self.pathologicalSessions {
      let window = HUDPrompterMetrics.windowed(finalized: text, volatileTail: "")
      let windowed = HUDPrompterMetrics.clampedLineCount(
        HUDPrompterMetrics.lineCount(for: StreamingDelivery.joined(window.finalized, ""))
      )
      let full = HUDPrompterMetrics.clampedLineCount(HUDPrompterMetrics.lineCount(for: text))
      XCTAssertEqual(windowed, full, "trim changed the card height for a \(text.count)-char session")
    }
  }

  /// Greedy wrapping starts at whatever character the window begins with, so a
  /// head that advanced with every syllable would re-wrap the visible lines on
  /// every tick. Quantized, it moves once per `windowStep` characters.
  func testTheHeadMovesInStepsRatherThanWithEverySyllable() {
    let words = (1...2000).map { "w\($0)" }.joined(separator: " ")
    let base = String(words.prefix(HUDPrompterMetrics.windowBudget + 40))
    let baseWindow = HUDPrompterMetrics.windowed(finalized: base, volatileTail: "").finalized

    // One more character: the head has not moved, so every line the card had
    // already wrapped is wrapped the same way on this tick.
    let oneMore = base + "x"
    let oneMoreWindow = HUDPrompterMetrics.windowed(finalized: oneMore, volatileTail: "").finalized
    XCTAssertTrue(
      oneMoreWindow.hasPrefix(baseWindow), "the window's head moved for a single character"
    )

    // A full step later: the head has moved on, and the window is back to the
    // length it started at rather than having grown by a whole step.
    let aStepLater = String(
      words.prefix(HUDPrompterMetrics.windowBudget + 40 + HUDPrompterMetrics.windowStep)
    )
    let steppedWindow = HUDPrompterMetrics.windowed(
      finalized: aStepLater, volatileTail: ""
    ).finalized
    XCTAssertEqual(steppedWindow.count, baseWindow.count)
    XCTAssertFalse(
      steppedWindow.hasPrefix(baseWindow.prefix(20)),
      "the window's head did not move after a full step"
    )
  }

  /// A recognizer that never finalizes puts the whole session in the volatile
  /// half; the bound has to hold there too.
  func testAVolatileHalfAloneIsWindowed() {
    let text = (1...4000).map { "word\($0)" }.joined(separator: " ")
    let window = HUDPrompterMetrics.windowed(finalized: "", volatileTail: text)
    XCTAssertEqual(window.finalized, "")
    XCTAssertLessThan(
      window.volatileTail.count,
      HUDPrompterMetrics.windowBudget + HUDPrompterMetrics.windowStep
    )
    XCTAssertTrue(window.volatileTail.hasSuffix("word4000"))
  }

  private static let growingSessions: [String] = {
    let words = (1...4000).map { "word\($0)" }
    return [1, 50, 200, 800, 2000, 4000].map { words.prefix($0).joined(separator: " ") }
  }()

  private static let pathologicalSessions: [String] = [
    // Narrowest glyphs the body font has, one per word: the most lines a given
    // character budget can be made to produce.
    String(repeating: "l ", count: 3000),
    String(repeating: "i ", count: 3000),
    // Ordinary speech.
    (1...4000).map { "word\($0)" }.joined(separator: " "),
    // One unbroken token, wrapped by the layout manager rather than by spaces.
    String(repeating: "genc2rust", count: 900),
    // Right at the boundary.
    String(repeating: "a ", count: HUDPrompterMetrics.windowBudget / 2),
  ]
}

