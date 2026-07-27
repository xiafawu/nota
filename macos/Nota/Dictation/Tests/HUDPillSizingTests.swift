import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// The pill's one hard sizing promise: it widens ONCE, when a rough draft
/// first appears, and never again while the user keeps talking.
@MainActor
final class HUDPillSizingTests: XCTestCase {
  // MARK: - Pure metric

  func testDraftBlockWidthIsNilWithoutADraft() {
    XCTAssertNil(HUDPillMetrics.draftBlockWidth(for: nil))
    XCTAssertNil(HUDPillMetrics.draftBlockWidth(for: ""))
  }

  func testDraftBlockWidthIsIdenticalForEveryDraftLength() {
    let widths = Self.growingDrafts.map { HUDPillMetrics.draftBlockWidth(for: $0) }
    XCTAssertEqual(Set(widths.compactMap { $0 }).count, 1)
    XCTAssertEqual(widths.count, Self.growingDrafts.count)
  }

  // MARK: - Laid-out pill

  func testPillWidthDoesNotGrowAsTheDraftGrows() {
    let widths = Self.growingDrafts.map { Self.fittingSize(draft: $0).width }
    XCTAssertFalse(widths.contains(0), "hosting view produced no layout: \(widths)")
    XCTAssertEqual(Set(widths).count, 1, "pill width stepped with the draft: \(widths)")
  }

  func testPillWidensOnceWhenTheDraftStarts() {
    let meterOnly = Self.fittingSize(draft: nil).width
    let withDraft = Self.fittingSize(draft: "hello").width
    XCTAssertGreaterThan(withDraft, meterOnly)
  }

  /// The draft block is fixed-width, so a longer draft can only spend the
  /// height it is allowed — and never more than `draftLineLimit` lines of it.
  func testPillHeightIsBoundedByTheDraftLineLimit() {
    let short = Self.fittingSize(draft: "hello").height
    let long = Self.fittingSize(draft: Self.growingDrafts.last ?? "").height
    XCTAssertGreaterThanOrEqual(long, short)
    XCTAssertLessThan(long, short * CGFloat(HUDPillMetrics.draftLineLimit + 1))
  }

  // MARK: - Helpers

  /// Successive drafts, each a superset of the last, spanning both sides of
  /// what a single line of the draft block can hold.
  private static let growingDrafts: [String] = {
    let words = (1...40).map { "word\($0)" }
    return (4...40).map { words.prefix($0).joined(separator: " ") }
  }()

  private static func fittingSize(draft: String?) -> CGSize {
    let view = NSHostingView(
      rootView: DictationHUDContentView(state: .listening(level: 0.4), roughDraft: draft)
    )
    view.layoutSubtreeIfNeeded()
    return view.fittingSize
  }
}
