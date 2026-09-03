import AppKit
import SwiftUI
import XCTest

@testable import Nota

/// **Ink is measured on the pixels, in both schemes** (owner, 2026-09-02:
/// "check text color and background don't conflict" — and, on seeing the
/// clock come out black on the dark ground, "evolve the test case to catch
/// this kind of issue").
///
/// The class of defect is a run drawn with a colour from outside `GroundInk`.
/// The ink tiers resolve against the scheme the view is given; a
/// `.primary`, a `labelColor`, or a literal does not follow it the same way,
/// and the only place that shows is the rendered bitmap. So each surface is
/// hosted over its own ground, drawn to a bitmap in light and in dark, and the
/// ink it produced is read back and required to (a) clear WCAG 4.5:1 against
/// the ground and (b) **change between the two schemes** — a colour that
/// happened to pass in both while never moving is exactly the fixed literal
/// this exists to catch.
///
/// `testTheProbeCatchesAFixedColour` is the positive control: black text over
/// the dark ground must be caught, or a green run here proves nothing.
@MainActor
final class SurfaceInkContrastTests: XCTestCase {

  private struct Ink {
    let background: (Double, Double, Double)
    let ink: (Double, Double, Double)
    var contrast: Double { Self.contrast(ink, background) }

    static func luminance(_ c: (Double, Double, Double)) -> Double {
      func channel(_ v: Double) -> Double {
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }
    static func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
      let la = luminance(a), lb = luminance(b)
      return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
  }

  /// Host, draw, and return the ground colour plus the most common colour
  /// that is clearly not the ground. Antialiased fringes are rarer than the
  /// solid interior of a glyph at 2×, so "most common" is the ink itself.
  private func measure<V: View>(
    _ scheme: ColorScheme, size: CGSize, @ViewBuilder _ content: () -> V
  ) -> Ink? {
    let root = content()
      .environment(\.colorScheme, scheme)
      .frame(width: size.width, height: size.height)
    let host = NSHostingView(rootView: AnyView(root))
    host.frame = CGRect(origin: .zero, size: size)
    let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    host.appearance = appearance
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    host.layoutSubtreeIfNeeded()
    defer {
      window.contentView = nil
      window.close()
    }

    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    host.displayIgnoringOpacity(host.bounds, in: context)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
      let c = rep.colorAt(x: x, y: y) ?? .black
      return (c.redComponent, c.greenComponent, c.blueComponent)
    }
    let background = rgb(4, rep.pixelsHigh - 4)
    let backgroundLuminance = Ink.luminance(background)
    // The ink is the pixel farthest from the ground in luminance: a glyph's
    // solid interior for real ink, and black itself for the defect. A
    // histogram was tried first and the dark wash's own gradient outvoted a
    // small run of text.
    var ink = background
    var farthest = 0.0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
      for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
        let c = rgb(x, y)
        let distance = abs(Ink.luminance(c) - backgroundLuminance)
        if distance > farthest {
          farthest = distance
          ink = c
        }
      }
    }
    // Nothing drawn at all — a wash's gradient never moves this far.
    guard farthest > 0.02 else { return nil }
    return Ink(background: background, ink: ink)
  }

  private static let floor: Double = 4.5

  private func assertFollowsTheScheme<V: View>(
    _ name: String, size: CGSize, file: StaticString = #filePath, line: UInt = #line,
    @ViewBuilder _ content: @escaping () -> V
  ) {
    guard let light = measure(.light, size: size, content),
      let dark = measure(.dark, size: size, content)
    else {
      XCTFail("\(name): the probe found no ink at all", file: file, line: line)
      return
    }
    XCTAssertGreaterThanOrEqual(
      light.contrast, Self.floor, "\(name) in light reads \(light.contrast)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      dark.contrast, Self.floor, "\(name) in dark reads \(dark.contrast)", file: file, line: line)
    let moved =
      abs(light.ink.0 - dark.ink.0) + abs(light.ink.1 - dark.ink.1) + abs(light.ink.2 - dark.ink.2)
    XCTAssertGreaterThan(
      moved, 0.5, "\(name): the ink did not change between light and dark — a fixed colour",
      file: file, line: line)
  }

  // MARK: - The surfaces

  /// The cluster's clock, on the recording ground. `.primary` here measured
  /// 1.2:1 in dark before it took a tier.
  func testTheLiveClockFollowsTheScheme() {
    assertFollowsTheScheme("clock", size: CGSize(width: 240, height: 80)) {
      ZStack {
        FieldBackground(role: .recording)
        SessionTimer(elapsed: 754, base: RecordingPaneMetrics.clockBase, tier: .body)
      }
    }
  }

  /// The live transcript's words and names, on the recording ground.
  func testTheLiveTranscriptFollowsTheScheme() {
    let rows = LiveTranscript.rows(
      LiveTranscript.blocks([
        LiveTranscriptLine(id: UUID(), text: "Right, so the migration lands next Tuesday.", endTime: 12, speaker: "Amara"),
        LiveTranscriptLine(id: UUID(), text: "We still owe the rollback note.", endTime: 19, speaker: "Kenny"),
      ]))
    assertFollowsTheScheme("live transcript", size: CGSize(width: 720, height: 240)) {
      ZStack {
        FieldBackground(role: .recording)
        LiveTranscriptView(rows: rows, volatileID: nil, bottomReserve: 0)
      }
    }
  }

  /// The finished document, title included, on the transcript ground.
  func testTheDocumentFollowsTheScheme() {
    let markdown = """
    # Final defense scheduling

    ## Full Transcript

    [00:00] **Brian Demsky:** Right, so the final defense has to land before the twelfth.
    [00:14] **Freya Wu:** I can send the email this afternoon.
    """
    let render = DocumentRender(
      meta: parseDocumentMeta(markdown),
      body: renderMarkdownAsRichText(markdown, sections: .transcript))
    assertFollowsTheScheme("document", size: CGSize(width: 720, height: 300)) {
      ZStack {
        FieldBackground(role: .transcript)
        RichTextViewer(attributedString: MainPaneView.documentBody(render, chips: []))
      }
    }
  }

  // MARK: - The control

  /// Black text over the dark ground must be caught, and a colour that does
  /// not move between schemes must be caught — or the three tests above are
  /// green against a blank probe.
  func testTheProbeCatchesAFixedColour() {
    let size = CGSize(width: 240, height: 80)
    let fixed = {
      ZStack {
        FieldBackground(role: .recording)
        Text("00:58").font(.system(size: 30, weight: .medium)).foregroundStyle(Color.black)
      }
    }
    guard let light = measure(.light, size: size, fixed)
    else { return XCTFail("the control found no ink in light") }
    XCTAssertGreaterThanOrEqual(light.contrast, Self.floor, "black on paper is fine")
    // Ink the probe cannot even find over the dark ground is the same
    // verdict as ink it finds and fails: `assertFollowsTheScheme` fails on
    // both. Either way it is caught.
    guard let dark = measure(.dark, size: size, fixed) else { return }
    XCTAssertLessThan(dark.contrast, Self.floor, "black on the dark ground was not caught")
    let moved =
      abs(light.ink.0 - dark.ink.0) + abs(light.ink.1 - dark.ink.1) + abs(light.ink.2 - dark.ink.2)
    XCTAssertLessThan(moved, 0.5, "a fixed colour read as following the scheme")
  }
}
