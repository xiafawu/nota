import XCTest
@testable import Nota

final class InjectionStrategyTests: XCTestCase {
  // MARK: - Default strategy resolution

  func testDefaultStrategyIsAccessibility() {
    let injector = TextInjector(overrides: [:])
    XCTAssertEqual(injector.resolveStrategy(for: nil), .accessibility)
    XCTAssertEqual(injector.resolveStrategy(for: "com.apple.TextEdit"), .accessibility)
    XCTAssertEqual(injector.resolveStrategy(for: "com.apple.Notes"), .accessibility)
    XCTAssertEqual(injector.resolveStrategy(for: "unknown.bundle.id"), .accessibility)
  }

  func testChromeOverridesToPaste() {
    let injector = TextInjector()
    XCTAssertEqual(injector.resolveStrategy(for: "com.google.Chrome"), .paste)
  }

  func testSlackOverridesToPaste() {
    let injector = TextInjector()
    XCTAssertEqual(injector.resolveStrategy(for: "com.slack.Slack"), .paste)
  }

  func testTerminalOverridesToCGEvent() {
    let injector = TextInjector()
    XCTAssertEqual(injector.resolveStrategy(for: "com.apple.Terminal"), .keyEvents)
    XCTAssertEqual(injector.resolveStrategy(for: "com.googlecode.iterm2"), .keyEvents)
    XCTAssertEqual(injector.resolveStrategy(for: "com.mitchellh.ghostty"), .keyEvents)
  }

  func testVSCodeOverridesToPaste() {
    let injector = TextInjector()
    XCTAssertEqual(injector.resolveStrategy(for: "com.microsoft.VSCode"), .paste)
  }

  // MARK: - Custom override table

  func testCustomOverrideRespected() {
    let customTable = [
      "com.example.app": PerAppOverride(forceStrategy: .keyEvents, pasteRestoreDelayMs: nil),
    ]
    let injector = TextInjector(overrides: customTable)
    XCTAssertEqual(injector.resolveStrategy(for: "com.example.app"), .keyEvents)
    // Unknown bundle still defaults to AX
    XCTAssertEqual(injector.resolveStrategy(for: "com.random.thing"), .accessibility)
  }

  func testOverrideWithoutForceStrategyDefaultsToAccessibility() {
    let customTable = [
      "com.example.app": PerAppOverride(forceStrategy: nil, pasteRestoreDelayMs: 200),
    ]
    let injector = TextInjector(overrides: customTable)
    XCTAssertEqual(injector.resolveStrategy(for: "com.example.app"), .accessibility)
  }

  func testEmptyOverrideTableAllDefaultsToAccessibility() {
    let injector = TextInjector(overrides: [:])
    let bundles = ["a.b.c", "d.e.f", nil, ""]
    for bundle in bundles {
      XCTAssertEqual(injector.resolveStrategy(for: bundle), .accessibility)
    }
  }

  // MARK: - Secure target refusal

  func testSecureFieldRefusalSetsNotice() async {
    let injector = TextInjector(overrides: [:])
    let target = FocusedTarget(
      bundleID: "com.apple.TextEdit",
      isSecureInput: true,
      accessibilityElement: nil
    )

    await injector.inject("secret password", target: target)

    XCTAssertNotNil(injector.lastSecureFieldNotice)
    XCTAssertTrue(injector.lastSecureFieldNotice?.contains("secure") ?? false
      || injector.lastSecureFieldNotice?.contains("password") ?? false)
  }

  func testSecureFieldDoesNotClearSecureNoticeOnSecondCallIfNormal() async {
    let injector = TextInjector(overrides: [:])

    // First: secure field
    let secureTarget = FocusedTarget(
      bundleID: "com.apple.TextEdit",
      isSecureInput: true,
      accessibilityElement: nil
    )
    await injector.inject("secret", target: secureTarget)
    XCTAssertNotNil(injector.lastSecureFieldNotice)

    // Second: normal field — notice should be cleared
    let normalTarget = FocusedTarget(
      bundleID: "com.apple.TextEdit",
      isSecureInput: false,
      accessibilityElement: nil
    )
    await injector.inject("hello", target: normalTarget)
    XCTAssertNil(injector.lastSecureFieldNotice)
  }

  // MARK: - Strategy description

  func testStrategyDescriptionsReadable() {
    XCTAssertEqual(InjectionStrategy.accessibility.description, "AX")
    XCTAssertEqual(InjectionStrategy.keyEvents.description, "CGEvent")
    XCTAssertEqual(InjectionStrategy.paste.description, "paste")
  }

  // MARK: - Default override table contents

  func testDefaultOverrideTableContainsExpectedKeys() {
    let table = TextInjector.defaultOverrideTable
    // Chrome family
    XCTAssertNotNil(table["com.google.Chrome"])
    XCTAssertNotNil(table["com.google.Chrome.canary"])
    XCTAssertNotNil(table["com.microsoft.edgemac"])
    // Slack
    XCTAssertNotNil(table["com.slack.Slack"])
    // Terminal
    XCTAssertNotNil(table["com.apple.Terminal"])
    XCTAssertNotNil(table["com.googlecode.iterm2"])
    // VSCode
    XCTAssertNotNil(table["com.microsoft.VSCode"])
  }

  func testDefaultOverrideTablePasteBundleUsesPaste() {
    let table = TextInjector.defaultOverrideTable
    for (bundleID, override) in table {
      if override.forceStrategy == .paste {
        XCTAssertNotNil(override.pasteRestoreDelayMs, "\(bundleID) should have a custom paste delay")
      }
    }
  }
}

final class FocusedTargetTests: XCTestCase {
  func testFocusedTargetEquality() {
    let a = FocusedTarget(bundleID: "com.example", isSecureInput: false, accessibilityElement: nil)
    let b = FocusedTarget(bundleID: "com.example", isSecureInput: false, accessibilityElement: nil)
    let c = FocusedTarget(bundleID: "com.example", isSecureInput: true, accessibilityElement: nil)

    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, c)
  }

  func testFocusedTargetCaptureDoesNotCrash() async {
    // Should not crash even without accessibility permissions.
    let target = await FocusedTarget.capture()
    // At minimum, bundleID should be non-nil when running under the test host (XCTest).
    // We just verify it doesn't crash and the struct is valid.
    XCTAssertFalse(target.isSecureInput) // Secure input not normally active during tests
  }

  func testCaptureRecordsThePidInjectionHasToPostTo() async throws {
    // Without it, CGEvent typing and the synthetic Cmd-V go to whatever is
    // frontmost when they are delivered rather than to the session's target.
    // Which app is frontmost during a test run is not ours to say — only that
    // whichever it was, the pid came back with it.
    let target = await FocusedTarget.capture()
    let pid = try XCTUnwrap(target.processID)
    XCTAssertGreaterThan(pid, 0)
  }

  func testASecureTargetStaysSecureOnEveryRecheck() {
    // The whole point of re-asking is that it can only get stricter, never
    // laxer, than what capture saw.
    let target = FocusedTarget(
      bundleID: "com.example",
      isSecureInput: true,
      accessibilityElement: nil
    )
    XCTAssertTrue(target.isSecureInputNow())
  }

  func testRecheckWithNothingReadableFallsBackToTheCapturedAnswer() {
    let target = FocusedTarget(
      bundleID: "com.example",
      isSecureInput: false,
      accessibilityElement: nil,
      processID: nil
    )
    XCTAssertFalse(target.isSecureInputNow())
  }
}
