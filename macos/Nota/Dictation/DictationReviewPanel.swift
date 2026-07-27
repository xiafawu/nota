import AppKit
import SwiftUI
import os

// MARK: - DictationReview

/// The pure core of review-before-insert: what Apply and Discard mean.
///
/// Kept free of AppKit so the two guarantees that matter — Discard inserts
/// nothing, Apply inserts exactly what the owner edited — are testable without
/// a panel, a window server, or an Accessibility target.
enum DictationReview {
  /// What the owner chose in the panel.
  enum Decision: Equatable {
    /// Insert the text as it stands in the editor.
    case apply(String)
    /// Close and insert nothing.
    case discard
  }

  /// A before/after pair for the auto-learn gate.
  struct LearnPair: Equatable {
    let before: String
    let after: String
  }

  /// What a decision means for the two things that can leave the panel: text
  /// into the target app, and diffs into the dictionary.
  struct Resolution: Equatable {
    /// Exactly what to inject. **Nil means nothing is inserted at all** — not
    /// an empty write, not a no-op injection call.
    let injection: String?
    /// Diffs worth handing to `AutoLearn`, most confident first.
    let learn: [LearnPair]
  }

  /// Resolve a decision against the text the panel was opened with.
  ///
  /// - `polished`: what the pipeline produced and pre-filled into the editor.
  /// - `offline`: the rules + dictionary result behind it (equal to `polished`
  ///   when polish is off or failed).
  ///
  /// Two learn pairs, and they are not redundant:
  ///
  /// 1. `polished → edited` is the owner correcting the model. It is the
  ///    highest-confidence signal the app ever gets, and the form it replaces
  ///    is the exact wrong spelling that was on screen — recorded as a spoken
  ///    form so L2 rewrites it deterministically next session.
  /// 2. `offline → edited` is the diff the immediate path learns from
  ///    unconditionally, held back until the owner has actually endorsed the
  ///    text by applying it. Without it, review mode would learn strictly less
  ///    than the mode with no human in the loop.
  ///
  /// Discard yields neither: text the owner threw away must not teach anything.
  static func resolve(polished: String, offline: String, decision: Decision) -> Resolution {
    switch decision {
    case .discard:
      return Resolution(injection: nil, learn: [])

    case .apply(let raw):
      // The editor is a text view; a stray trailing newline is a keystroke, not
      // an edit, and must not be typed into the target either.
      let edited = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !edited.isEmpty else {
        // Emptying the box and applying is a discard by another name.
        return Resolution(injection: nil, learn: [])
      }

      var pairs: [LearnPair] = []
      let polished = polished.trimmingCharacters(in: .whitespacesAndNewlines)
      if !polished.isEmpty, polished != edited {
        pairs.append(LearnPair(before: polished, after: edited))
      }
      let offline = offline.trimmingCharacters(in: .whitespacesAndNewlines)
      if !offline.isEmpty, offline != edited, !pairs.contains(where: { $0.before == offline }) {
        pairs.append(LearnPair(before: offline, after: edited))
      }
      return Resolution(injection: edited, learn: pairs)
    }
  }

  /// Words in the editor, for the card's title row.
  ///
  /// Whitespace-separated runs, which is what a person counts when they glance
  /// at a paragraph — not `enumerateSubstrings(.byWords)`, which splits
  /// `genc2rust` and `package.json` into several and would make the count
  /// disagree with the text in front of them.
  static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
  }
}

// MARK: - Presenting

/// One review's contract with whatever shows it.
///
/// The callbacks carry the decision and nothing else: everything the session
/// needs at Apply time (its target pid, the text it started from) is held by
/// the controller, because by then the session that produced it is over.
@MainActor
struct DictationReviewRequest {
  /// Polished text, pre-filled into the editor.
  let text: String
  /// Called with the text as EDITED when the owner applies.
  let onApply: (String) -> Void
  /// Called when the owner discards, closes, or is pre-empted.
  let onDiscard: () -> Void
}

/// The panel as the controller sees it. Injectable so the review branch can be
/// driven in tests without a window server.
@MainActor
protocol DictationReviewPresenting: AnyObject {
  var isPresenting: Bool { get }
  /// Put this review on screen. **Returns whether it actually got there** — a
  /// card that never reached the screen is this mode's total output missing,
  /// and the caller has to say so rather than wait for a decision that can
  /// never come. A false return delivers no callback: the request is dropped
  /// here.
  @discardableResult
  func present(_ request: DictationReviewRequest) -> Bool
  /// Take the panel down without applying. Idempotent, and safe to call from
  /// inside a decision callback.
  func dismiss()
}

// MARK: - DictationReviewPresenter

/// Owns the review panel and the key monitor that gives it ⌘↩ / Escape.
@MainActor
final class DictationReviewPresenter: NSObject, DictationReviewPresenting {
  private static let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.review")

  private var panel: DictationReviewPanel?
  private let model = DictationReviewModel()
  private var keyMonitor: Any?
  /// The review currently on screen. Taken — not merely read — the instant a
  /// decision lands, which is what makes Apply-then-close fire exactly one
  /// callback.
  private var pending: DictationReviewRequest?

  var isPresenting: Bool { pending != nil }

  @discardableResult
  func present(_ request: DictationReviewRequest) -> Bool {
    // A second present without a decision would strand the first session's
    // text: close it out as a discard so nothing of it is ever inserted.
    dismiss()

    pending = request
    model.text = request.text
    model.onApply = { [weak self] text in self?.finish(.apply(text)) }
    model.onDiscard = { [weak self] in self?.finish(.discard) }

    guard show() else {
      // Nothing is on screen and nothing ever will be for this request, so it
      // is dropped here rather than left pending: a review waiting on a
      // decision that cannot be made suppresses the pill for every session
      // after it. The caller reports the failure — it is the only party that
      // still holds the text.
      pending = nil
      close()
      Self.logger.fault(
        "Review panel has no window device after two attempts — the card cannot be shown."
      )
      return false
    }
    return true
  }

  func dismiss() {
    guard pending != nil else { return close() }
    finish(.discard)
  }

  // MARK: - Private

  /// Get the card on screen, with one bounded heal.
  ///
  /// `orderFrontRegardless()` fails silently: on 2026-07-27 it left the HUD
  /// panel with `windowNumber == 0` for a day, rendering into a window that did
  /// not exist. The pill has `HUDVisibilityMonitor` for exactly this, and the
  /// review card needs it more — it is the only thing a review session puts on
  /// screen, and `isReviewing` suppresses the pill while one is open, so a
  /// zombie panel means the owner sees nothing at all. A dead server-side
  /// window cannot be revived, only replaced, so the retry is a *fresh*
  /// NSPanel; a second failure is the same failure and stops.
  private func show() -> Bool {
    if let existing = panel, configureAndShow(existing) { return true }

    if let dead = panel {
      Self.logger.error("Recreating the review panel after a failed show.")
      // Delegate first: `close()` on a panel still holding this presenter as
      // its delegate would deliver `windowWillClose` — a discard of the very
      // review being opened.
      dead.delegate = nil
      dead.orderOut(nil)
      dead.close()
      panel = nil
    }
    return configureAndShow(DictationReviewPanel(model: model))
  }

  /// Size, place, wire and order one panel front.
  ///
  /// No `NSApp.activate` anywhere on this path. The panel carries
  /// `.nonactivatingPanel`, so it takes key status — and typing — without Nota
  /// becoming the active app: the app being dictated into stays frontmost, the
  /// home window never surfaces behind the card, and there is no focus to hand
  /// back when the panel goes away.
  private func configureAndShow(_ panel: DictationReviewPanel) -> Bool {
    self.panel = panel
    panel.delegate = self
    panel.sizeToFitContent()
    panel.reposition()
    installKeyMonitor(for: panel)
    return panel.present()
  }

  /// Land a decision, exactly once.
  ///
  /// Every route out of the panel — the two buttons, the key monitor, a
  /// programmatic close, a pre-empting `dismiss()` — comes through here, and
  /// the request is *taken* before the callback runs. Clearing the handler in
  /// the caller and invoking it afterwards is the shape that broke: the
  /// callback's own "is a review still open?" guard then answered no and
  /// swallowed the discard, leaving the controller believing the panel was up.
  private func finish(_ decision: DictationReview.Decision) {
    guard let request = pending else { return }
    pending = nil
    close()
    switch decision {
    case .apply(let text): request.onApply(text)
    case .discard: request.onDiscard()
    }
  }

  private func close() {
    removeKeyMonitor()
    panel?.orderOut(nil)
  }

  /// ⌘↩ and Escape, taken before the text view sees them.
  ///
  /// Not `.keyboardShortcut` alone: the editor is the first responder and
  /// `NSTextView` answers `cancelOperation:` itself, so Escape would never
  /// reach a SwiftUI cancel button. Scoped to this panel's own events, and torn
  /// down with it — a monitor left installed would swallow Escape everywhere
  /// else in the app.
  private func installKeyMonitor(for panel: NSPanel) {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
      guard let self, let panel, event.window === panel else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      switch event.keyCode {
      case 53: // Escape
        self.finish(.discard)
        return nil
      case 36 where flags.contains(.command): // Return
        self.finish(.apply(self.model.text))
        return nil
      default:
        return event
      }
    }
  }

  private func removeKeyMonitor() {
    guard let keyMonitor else { return }
    NSEvent.removeMonitor(keyMonitor)
    self.keyMonitor = nil
  }
}

extension DictationReviewPresenter: NSWindowDelegate {
  /// A closed panel is a discard, same as Escape.
  func windowWillClose(_ notification: Notification) {
    finish(.discard)
  }
}

// MARK: - DictationReviewModel

/// The editable text and the two decisions, shared between the panel and its
/// SwiftUI content.
@MainActor
final class DictationReviewModel: ObservableObject {
  @Published var text: String = ""

  var onApply: ((String) -> Void)?
  var onDiscard: (() -> Void)?

  func apply() { onApply?(text) }
  func discard() { onDiscard?() }
}

// MARK: - DictationReviewPanel

/// Floating card holding the finished text until the owner decides.
///
/// Two constraints pull against each other here. The owner types in it, so it
/// MUST become key — which a borderless window refuses by default. But Nota
/// must NOT become the active app: activating raises the home window over
/// whatever is being dictated into and puts the owner one Cmd-Tab away from
/// their own text. `.nonactivatingPanel` plus an explicit `canBecomeKey` is the
/// combination that gives keyboard input to a panel of an inactive app (the
/// Spotlight pattern), and it is why nothing on the review path activates Nota.
@MainActor
final class DictationReviewPanel: NSPanel {
  private static let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.review")

  private let hostingView: NSHostingView<DictationReviewView>

  /// The owner types in this panel. A borderless window answers false, so it is
  /// said explicitly.
  override var canBecomeKey: Bool { true }
  /// Key, never main: main belongs to a document window of the *active* app,
  /// and the whole point of this panel is that Nota never becomes one.
  override var canBecomeMain: Bool { false }

  init(model: DictationReviewModel) {
    hostingView = NSHostingView(rootView: DictationReviewView(model: model))
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
      // Borderless: the card draws its own chrome (see DictationReviewView), so
      // a title bar would be a second, lighter frame around it.
      // Nonactivating: keyboard input without making Nota the active app.
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = .clear
    // No window shadow: a window shadow can only draw INSIDE the window frame,
    // which turns it into a dark rectangle behind a rounded card. The card
    // draws its own SwiftUI shadow inside `DictationReviewView.shadowMargin`,
    // exactly as the HUD pill does.
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isFloatingPanel = true
    // AFTER isFloatingPanel, which silently rewrites `level` when set (the same
    // ordering trap documented on DictationHUDPanel). `.statusBar` rather than
    // `.floating`: the panel no longer activates Nota, so nothing raises it over
    // a fullscreen app the way activation used to — and a review panel that is
    // invisible behind a fullscreen editor loses the session's text.
    level = .statusBar
    // AppKit-drawn pieces inside the hosting view (the editor's insertion point,
    // selection, scrollers) follow the window's appearance, not the SwiftUI
    // environment. The card is dark in both system themes; so is this.
    appearance = NSAppearance(named: .darkAqua)

    contentView = hostingView
  }

  /// Order the card onscreen and give it the keyboard, without activating Nota.
  ///
  /// `orderFrontRegardless()` rather than `makeKeyAndOrderFront(_:)`: ordering
  /// front from an *inactive* app is deferred until the app activates, and this
  /// app never will. Key status is then asked for separately, which is the part
  /// `.nonactivatingPanel` makes legal.
  ///
  /// Returns whether the card actually reached the screen — see
  /// `verifyWindowDevice`.
  @discardableResult
  func present() -> Bool {
    orderFrontRegardless()
    guard verifyWindowDevice() else { return false }
    makeKey()
    focusEditor()
    return true
  }

  /// True when AppKit gave this panel a server-side window.
  ///
  /// `orderFrontRegardless()` returns nothing and fails silently: on 2026-07-27
  /// it left the HUD panel with `windowNumber == 0` for an entire day. The same
  /// check guards the pill (`DictationHUDPanel.verifyWindowDevice`); here it
  /// guards the one window a review session has, with nothing else on screen to
  /// notice its absence.
  @discardableResult
  func verifyWindowDevice() -> Bool {
    let number = windowNumber
    guard number <= 0 else { return true }
    Self.logger.error(
      """
      Review panel has no window device after orderFrontRegardless \
      (windowNumber=\(number, privacy: .public), \
      isVisible=\(self.isVisible, privacy: .public), \
      frame=\(NSStringFromRect(self.frame), privacy: .public)) — zombie WindowServer state.
      """
    )
    return false
  }

  /// Put the caret in the editor.
  ///
  /// Explicit AppKit rather than SwiftUI `@FocusState`: this panel is
  /// borderless and nonactivating, the two cases where SwiftUI's focus plumbing
  /// is least reliable, and "the owner can type" is the whole reason the panel
  /// exists. One authority, asserted by test.
  ///
  /// Returns whether the editor took first responder.
  @discardableResult
  func focusEditor() -> Bool {
    guard let editor = Self.firstTextView(in: contentView) else {
      // The hosting view had not built its text view yet — retry once on the
      // next turn of the run loop rather than leaving the caret nowhere.
      DispatchQueue.main.async { [weak self] in
        guard let self, let editor = Self.firstTextView(in: self.contentView) else {
          Self.logger.error("Review panel has no editor to focus")
          return
        }
        _ = self.makeFirstResponder(editor)
      }
      return false
    }
    return makeFirstResponder(editor)
  }

  /// First `NSTextView` in the hosted content — SwiftUI's `TextEditor` is one.
  /// Internal so a test can type into the same view the owner would.
  static func firstTextView(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
      if let found = firstTextView(in: subview) { return found }
    }
    return nil
  }

  /// Grow the panel to whatever the card wants, within reason.
  ///
  /// The window is deliberately larger than the card: `shadowMargin` of
  /// transparent padding on every side is where the card's shadow falls.
  func sizeToFitContent() {
    hostingView.layoutSubtreeIfNeeded()
    let fitting = hostingView.fittingSize
    guard fitting.width > 0, fitting.height > 0 else { return }
    let chrome = DictationReviewView.shadowMargin * 2
    setContentSize(
      NSSize(
        width: max(fitting.width, DictationReviewView.minCardWidth + chrome),
        height: min(
          max(fitting.height, DictationReviewView.minCardHeight + chrome),
          DictationReviewView.maxCardHeight + chrome
        )
      )
    )
  }

  /// Put the card where the pill was: centered under the focused window of the
  /// app being dictated into.
  ///
  /// All math is done on the *card* rect (window frame inset by `shadowMargin`)
  /// — treating the window frame as the card renders every gap 24pt too large.
  /// The frontmost app is read here and is still the target: nothing on this
  /// path activates Nota.
  func reposition() {
    let margin = DictationReviewView.shadowMargin
    let card = NSSize(
      width: max(frame.width - margin * 2, 0),
      height: max(frame.height - margin * 2, 0)
    )

    let anchor = DictationHUDPanel.frontmostAppFocusedWindowFrame()
    guard let screen = anchor.flatMap({ rect in
      NSScreen.screens.first { $0.frame.intersects(rect) }
    })
      ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
      ?? NSScreen.main
    else { return }
    let visible = screen.visibleFrame

    let centerX = anchor?.midX ?? visible.midX
    // Under the anchor window if it fits, otherwise centered on the screen —
    // a card the owner has to type into must never hang off the bottom edge.
    let preferredY = anchor.map { $0.minY - 12 - card.height }
      ?? (visible.midY - card.height / 2)

    let x = max(visible.minX + 8, min(centerX - card.width / 2, visible.maxX - card.width - 8))
    let y = max(visible.minY + 8, min(preferredY, visible.maxY - card.height - 8))
    setFrameOrigin(NSPoint(x: x - margin, y: y - margin))
  }
}

// MARK: - DictationReviewView

/// The card: one dark translucent surface, a hairline, and no other chrome —
/// the same grammar as the HUD pill it replaces on screen.
struct DictationReviewView: View {
  @ObservedObject var model: DictationReviewModel

  /// Transparent margin around the card reserved for its drop shadow. A window
  /// cannot draw outside its own frame, so the room has to come from inside.
  static let shadowMargin: CGFloat = 24
  static let minCardWidth: CGFloat = 520
  static let minCardHeight: CGFloat = 200
  static let maxCardHeight: CGFloat = 520

  private static let cornerRadius: CGFloat = 16

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      titleRow
      editor
      footer
    }
    .padding(18)
    .frame(
      minWidth: Self.minCardWidth,
      minHeight: Self.minCardHeight,
      alignment: .topLeading
    )
    // Same body as the pill: fixed dark translucent fill with light content
    // forced on top of it, rather than an adaptive material that reads
    // light-and-frosted over light content.
    .background { cardShape.fill(Color(white: 0.09).opacity(0.9)) }
    .overlay { cardShape.strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5) }
    .environment(\.colorScheme, .dark)
    .shadow(color: .black.opacity(0.32), radius: 18, y: 6)
    .padding(Self.shadowMargin)
  }

  private var cardShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
  }

  private var titleRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text("Review dictation")
        .font(.headline)
      Spacer(minLength: 12)
      Text(wordCountLabel)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
  }

  private var wordCountLabel: String {
    let count = DictationReview.wordCount(model.text)
    return count == 1 ? "1 word" : "\(count) words"
  }

  /// Borderless by construction: no bezel, no scroll background, no focus ring
  /// box. The card is the container; a second box inside it is what made the
  /// panel read as a bare text input.
  private var editor: some View {
    TextEditor(text: $model.text)
      .font(.body)
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .frame(minHeight: 116)
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Text("Nothing is inserted until you apply.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer(minLength: 12)

      Button { model.discard() } label: {
        ReviewButtonLabel(title: "Discard", shortcut: "esc")
      }
      .buttonStyle(ReviewButtonStyle(prominent: false))
      .keyboardShortcut(.cancelAction)

      Button { model.apply() } label: {
        ReviewButtonLabel(title: "Apply", shortcut: "⌘↩")
      }
      .buttonStyle(ReviewButtonStyle(prominent: true))
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }
}

// MARK: - Card buttons

/// Label + its shortcut, the way a command card states one.
private struct ReviewButtonLabel: View {
  let title: String
  let shortcut: String

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.callout.weight(.medium))
      Text(shortcut)
        .font(.caption2)
        .opacity(0.55)
    }
  }
}

/// Buttons drawn on the card rather than by AppKit.
///
/// `.bordered` / `.borderedProminent` render the system's own chrome, which is
/// the light-mode-shaped thing the redesign is removing — the card commits to a
/// single dark look in both system themes, so its controls have to as well.
private struct ReviewButtonStyle: ButtonStyle {
  let prominent: Bool
  @Environment(\.isEnabled) private var isEnabled

  private static let cornerRadius: CGFloat = 8

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    return configuration.label
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.8))
      .background { shape.fill(fill(pressed: configuration.isPressed)) }
      .overlay {
        shape.strokeBorder(
          Color.white.opacity(prominent ? 0 : 0.18),
          lineWidth: 0.5
        )
      }
      .opacity(isEnabled ? 1 : 0.4)
      .contentShape(shape)
  }

  private func fill(pressed: Bool) -> Color {
    if prominent {
      return Color.accentColor.opacity(pressed ? 0.7 : 1)
    }
    return Color.white.opacity(pressed ? 0.2 : 0.08)
  }
}

#if DEBUG
extension DictationReviewModel {
  static var preview: DictationReviewModel {
    let model = DictationReviewModel()
    model.text = "Ship the gency to rust patch before the review."
    return model
  }
}

#Preview {
  DictationReviewView(model: .preview)
}
#endif
