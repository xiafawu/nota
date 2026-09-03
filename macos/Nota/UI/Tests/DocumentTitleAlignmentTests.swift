import AppKit
import XCTest

@testable import Nota

/// The title sits on the same left edge as the spoken words (owner,
/// 2026-09-02: "align the transcription verbatim with the recording title").
/// The edge is read off the body's own first paragraph, never recomputed, so
/// the two cannot drift.
@MainActor
final class DocumentTitleAlignmentTests: XCTestCase {

  private static let withSpeakers = """
  # Final defense scheduling

  ## Full Transcript

  [00:00] **Brian Demsky:** Right, so the final defense has to land before the twelfth.
  [00:14] **Freya Wu:** I can send the email this afternoon.
  """

  private static let withoutSpeakers = """
  # Quick memo

  ## Full Transcript

  [00:00] Book the small room and tell the committee.
  """

  private static func indents(_ markdown: String) -> (title: CGFloat, words: CGFloat) {
    let body = renderMarkdownAsRichText(markdown, sections: .transcript)
    let render = DocumentRender(meta: parseDocumentMeta(markdown), body: body)
    let drawn = MainPaneView.documentBody(render, chips: [])
    let title = (drawn.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    let words = (body.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    return (title?.firstLineHeadIndent ?? -1, words?.headIndent ?? -1)
  }

  func testTheTitleStartsWhereTheWordsStart() {
    let (title, words) = Self.indents(Self.withSpeakers)
    XCTAssertGreaterThan(words, 0, "a speaker document draws its words past a name column")
    XCTAssertEqual(title, words, accuracy: 0.01)
  }

  func testADocumentWithNoNamesKeepsItsTitleAtTheColumnEdge() {
    let (title, words) = Self.indents(Self.withoutSpeakers)
    XCTAssertEqual(words, 0)
    XCTAssertEqual(title, 0)
  }
}
