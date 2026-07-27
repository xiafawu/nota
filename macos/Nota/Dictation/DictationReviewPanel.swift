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
  func present(_ request: DictationReviewRequest)
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
  /// The decision handler for the panel currently on screen. Cleared the
  /// instant a decision is taken, which is what makes Apply-then-close fire
  /// exactly one callback.
  private var decide: ((DictationReview.Decision) -> Void)?

  var isPresenting: Bool { decide != nil }

  func present(_ request: DictationReviewRequest) {
    // A second present without a decision would strand the first session's
    // text: close it out as a discard so nothing of it is ever inserted.
    dismiss()

    decide = { [weak self] decision in
      guard let self, self.decide != nil else { return }
      self.decide = nil
      self.close()
      switch decision {
      case .apply(let text): request.onApply(text)
      case .discard: request.onDiscard()
      }
    }

    model.text = request.text
    model.onApply = { [weak self] text in self?.decide?(.apply(text)) }
    model.onDiscard = { [weak self] in self?.decide?(.discard) }

    let panel = self.panel ?? DictationReviewPanel(model: model)
    self.panel = panel
    panel.delegate = self
    panel.sizeToFitContent()
    panel.reposition()
    installKeyMonitor(for: panel)

    // Deliberate activation: the owner is about to type into this panel, and a
    // panel in a background app cannot take key focus. Safe here in a way it
    // would not be mid-session — the injection target was captured when the
    // hotkey went down and is addressed by pid, not by what is frontmost now.
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    model.focusEditor()
  }

  func dismiss() {
    guard let decide else { return close() }
    self.decide = nil
    close()
    decide(.discard)
  }

  // MARK: - Private

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
        self.decide?(.discard)
        return nil
      case 36 where flags.contains(.command): // Return
        self.decide?(.apply(self.model.text))
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
  /// The close button is a discard, same as Escape.
  func windowWillClose(_ notification: Notification) {
    guard let decide else { return }
    self.decide = nil
    removeKeyMonitor()
    decide(.discard)
  }
}

// MARK: - DictationReviewModel

/// The editable text and the two decisions, shared between the panel and its
/// SwiftUI content.
@MainActor
final class DictationReviewModel: ObservableObject {
  @Published var text: String = ""
  /// Bumped to move focus into the editor when a panel opens; the editor keys
  /// its `@FocusState` off it so a second review focuses the box again.
  @Published fileprivate var focusToken: Int = 0

  var onApply: ((String) -> Void)?
  var onDiscard: (() -> Void)?

  func apply() { onApply?(text) }
  func discard() { onDiscard?() }
  func focusEditor() { focusToken &+= 1 }
}

// MARK: - DictationReviewPanel

/// Floating panel holding the finished text until the owner decides.
///
/// Unlike the HUD pill this panel MUST become key — the owner types in it — so
/// it is titled (a borderless window answers `canBecomeKey` with false) and
/// says so explicitly on top of that.
@MainActor
final class DictationReviewPanel: NSPanel {
  private let hostingView: NSHostingView<DictationReviewView>

  override var canBecomeKey: Bool { true }

  init(model: DictationReviewModel) {
    hostingView = NSHostingView(rootView: DictationReviewView(model: model))
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
      styleMask: [.titled, .closable, .utilityWindow],
      backing: .buffered,
      defer: false
    )

    title = "Review Dictation"
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isFloatingPanel = true
    // AFTER isFloatingPanel, which silently rewrites `level` when set (the same
    // ordering trap documented on DictationHUDPanel). Floating is right here:
    // the panel is key, so it does not need to outrank a fullscreen app the way
    // the pill does.
    level = .floating

    contentView = hostingView
  }

  /// Grow the panel to whatever the content wants, within reason.
  func sizeToFitContent() {
    hostingView.layoutSubtreeIfNeeded()
    let fitting = hostingView.fittingSize
    guard fitting.width > 0, fitting.height > 0 else { return }
    setContentSize(
      NSSize(width: max(fitting.width, 520), height: min(max(fitting.height, 220), 520))
    )
  }

  /// Put the panel where the pill was: centered under the focused window of
  /// the app being dictated into.
  ///
  /// Read before Nota activates, so the frontmost app is still the target.
  func reposition() {
    let anchor = DictationHUDPanel.frontmostAppFocusedWindowFrame()
    guard let screen = anchor.flatMap({ rect in
      NSScreen.screens.first { $0.frame.intersects(rect) }
    })
      ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
      ?? NSScreen.main
    else { return }
    let visible = screen.visibleFrame
    let size = frame.size

    let centerX = anchor?.midX ?? visible.midX
    // Under the anchor window if it fits, otherwise centered on the screen —
    // a panel the owner has to type into must never hang off the bottom edge.
    let preferredY = anchor.map { $0.minY - 12 - size.height }
      ?? (visible.midY - size.height / 2)

    let x = max(visible.minX + 8, min(centerX - size.width / 2, visible.maxX - size.width - 8))
    let y = max(visible.minY + 8, min(preferredY, visible.maxY - size.height - 8))
    setFrameOrigin(NSPoint(x: x, y: y))
  }
}

// MARK: - DictationReviewView

struct DictationReviewView: View {
  @ObservedObject var model: DictationReviewModel
  @FocusState private var isEditorFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextEditor(text: $model.text)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .frame(minWidth: 470, minHeight: 120)
        .focused($isEditorFocused)

      HStack(spacing: 12) {
        Text("Nothing is inserted until you apply.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Button("Discard") { model.discard() }
          .keyboardShortcut(.cancelAction)
        Button("Apply") { model.apply() }
          .keyboardShortcut(.return, modifiers: .command)
          .buttonStyle(.borderedProminent)
          .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(16)
    .onAppear { isEditorFocused = true }
    .onChange(of: model.focusToken) { _, _ in isEditorFocused = true }
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
