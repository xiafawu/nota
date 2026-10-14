import XCTest

@testable import Nota

/// **Pin rides on the row, not on the open button** (KB-7 with P-C8).
///
/// While a file transcription runs, the row's open button is `.disabled` and
/// everything else on the row is promised to stay live (P-C8). The named Pin
/// action used to be attached to that disabled button, so the one verb an
/// assistive-tech user had for pinning sat on the one element the run had
/// switched off. It is on the row container now.
///
/// Read from the source: the row is private, and SwiftUI publishes no
/// accessibility tree for an unhosted hosting view.
final class HistoryDrawerRowAccessibilityTests: XCTestCase {
  func testPinIsNamedOnTheRowContainerAndNotOnTheDisabledOpenButton() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("HistoryDrawerView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    let start = try XCTUnwrap(
      source.range(of: "private struct HistoryDrawerRow: View {"),
      "could not find the drawer row in HistoryDrawerView.swift")
    let end = try XCTUnwrap(
      source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
    let row = String(source[start.lowerBound..<end.upperBound])

    let action =
      ".accessibilityAction(named: HistoryRowAvailability.pinActionName(isPinned: isPinned))"
    XCTAssertEqual(
      row.components(separatedBy: action).count - 1, 1,
      "the row should name Pin exactly once")

    // The open button's modifier chain runs from its `.disabled` to the hover
    // actions that sit beside it. The action may not be in there.
    let disabled = try XCTUnwrap(row.range(of: ".disabled(!canOpen)"))
    let hoverActions = try XCTUnwrap(
      row.range(of: "// Hover actions live OUTSIDE", range: disabled.upperBound..<row.endIndex))
    XCTAssertFalse(
      row[disabled.upperBound..<hoverActions.lowerBound].contains("accessibilityAction"),
      "Pin is attached to the open button again, which is disabled while a transcription runs")

    // On the row: after the container's own hover handler, on a container element.
    let rowHover = try XCTUnwrap(row.range(of: ".onHover { isHovered = $0 }"))
    let actionRange = try XCTUnwrap(row.range(of: action))
    XCTAssertGreaterThan(
      actionRange.lowerBound, rowHover.upperBound,
      "Pin is not on the row container")
    let container = try XCTUnwrap(
      row.range(of: ".accessibilityElement(children: .contain)", range: rowHover.upperBound..<row.endIndex),
      "the row is not a container element, so its buttons would be folded into it")
    XCTAssertLessThan(container.lowerBound, actionRange.lowerBound)
  }
}
