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

  /// What the card holds after a continuation session's text is added to it.
  ///
  /// Append-only, for the same reason streaming delivery into a live document
  /// is: `buffer` is what the OWNER has in the box, edits and all, and those
  /// edits are theirs. The earlier text is never regenerated from the pipeline
  /// — only extended.
  ///
  /// The separator is `StreamingDelivery.joined`'s: exactly one space, unless
  /// one side already brings whitespace. That covers both cases the same way —
  /// a buffer cut off mid-sentence and one ending in a full stop both want a
  /// single space — and it keeps a deliberate newline the owner typed at the
  /// end of the box intact rather than collapsing it.
  static func appended(buffer: String, addition: String) -> String {
    let addition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !addition.isEmpty else { return buffer }
    guard !buffer.isEmpty else { return addition }
    return StreamingDelivery.joined(buffer, addition)
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

// MARK: - ReviewDraftMetrics

/// How much of a recording session's live draft the card is allowed to render.
///
/// Since 2026-08-03 the draft is not a block of its own — it is drawn as a
/// dimmed suffix inside the editor, one text box for the whole card (owner:
/// "merge those 2 things together, into one text box"). What survived the merge
/// is the bound, and it survived for exactly the reason it was written: the
/// suffix is fed by the volatile recognizer feed, which arrives many times a
/// second carrying a string that grows for as long as the owner keeps talking,
/// and it is laid out on the main actor inside a text view.
///
/// `windowed` head-trims past `windowBudget` before anything is laid out, so the
/// cost per tick stops growing with the session. The cut lands in text that has
/// already scrolled off the top of the visible suffix.
///
/// Kept as its own type rather than borrowing `HUDPrompterMetrics`: the card is
/// narrower than the prompter and shows fewer lines of draft, and the prompter's
/// budget is derived from *its* geometry. The technique is borrowed; the
/// numbers are not.
enum ReviewDraftMetrics {
  /// Characters of the continuation the editor measures and draws as a suffix.
  ///
  /// Comfortably past what the editor can show below the owner's buffer even at
  /// the font's narrowest glyphs, so nothing that could be visible is outside
  /// the window.
  static let windowBudget = 800

  /// How far the text may overrun `windowBudget` before the head moves.
  ///
  /// Quantized rather than sliding, for the reason `HUDPrompterMetrics` gives:
  /// greedy wrapping starts at whatever character the window begins with, so a
  /// head that advanced by a character per tick would re-wrap every visible
  /// line on every tick.
  static let windowStep = 300

  /// The `(finalized, volatileTail)` pair the editor actually draws.
  ///
  /// Head-trimmed only. The newest words — the ones the owner is watching for,
  /// and the only reason the suffix exists — are never touched.
  static func windowed(
    finalized: String,
    volatileTail: String
  ) -> (finalized: String, volatileTail: String) {
    let overflow = finalized.count + volatileTail.count - windowBudget
    guard overflow > 0 else { return (finalized, volatileTail) }
    let cut = (overflow / windowStep) * windowStep
    guard cut > 0 else { return (finalized, volatileTail) }
    guard cut < finalized.count else {
      return ("", String(volatileTail.dropFirst(cut - finalized.count)))
    }
    return (String(finalized.dropFirst(cut)), volatileTail)
  }

  /// The two runs drawn: finalized text, then the volatile tail.
  ///
  /// The separator rides on the finalized run for the same reason it does in
  /// the prompter — `StreamingDelivery.joined` adds no second space when
  /// Apple's volatile result already brought its own, and an unconditional
  /// `Text(" ")` between the runs would draw one anyway.
  static func runs(
    finalized: String,
    volatileTail: String
  ) -> (finalized: String, volatileTail: String) {
    (
      finalized + StreamingDelivery.joiningSeparator(finalized, volatileTail),
      volatileTail
    )
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
  /// What is in the editor right now, or nil when no card is up.
  ///
  /// A continuation appends to *this*, not to the text the pipeline last
  /// produced: by the time the owner triggers another session they may have
  /// already corrected half the card, and regenerating from the pipeline would
  /// throw those edits away.
  var editorText: String? { get }
  /// Replace the editor's contents. False when no card is up to replace.
  @discardableResult
  func replaceEditorText(_ text: String) -> Bool
  /// Show (or clear) the card's "a continuation is recording into me" state.
  /// While it is set the card refuses Apply and Discard — the decision is about
  /// a batch that is still being spoken.
  func setListening(_ listening: Bool)
  /// The live draft of the session recording into this card.
  ///
  /// **Display only.** Nothing here is ever written into the buffer: the
  /// session's text reaches the owner's buffer once, at stop, through
  /// `DictationReview.appended`. Since 2026-08-03 it is *rendered* inside the
  /// editor as a dimmed suffix rather than in a block of its own — one text box
  /// — but the invariant is unchanged and is what makes that safe.
  ///
  /// The same `HUDDraft` the HUD is fed, deliberately: it is literally the same
  /// two strings off the same recognizer, and a second type carrying them would
  /// be one more thing to keep in step.
  func setDraft(_ draft: HUDDraft)
  /// Called when the owner ends the session from the card itself — the Finish
  /// button, or ⌘↩ while it is recording.
  ///
  /// A presenter-level callback rather than one more field on
  /// `DictationReviewRequest`: `present` runs once per *card*, and a card
  /// survives any number of continuation sessions, each of which the owner must
  /// be able to end from the same button.
  var onFinishRecording: (() -> Void)? { get set }
  /// How strongly the card's glass is tinted (`GlassTint`).
  ///
  /// A presenter-level property rather than a field on
  /// `DictationReviewRequest`, for the reason `onFinishRecording` is one: the
  /// setting can move while a card is up, and a request is written once per
  /// card. The controller assigns it from `applySettings()`, so a Settings visit
  /// retints an open card and every card after it.
  var glassTintAlpha: Double { get set }
  /// Show (or clear) a session failure in the card's status line.
  ///
  /// The card is the only surface a review session has — the HUD is suppressed
  /// for the whole time one is open — so it has to be able to say that
  /// something went wrong. Nil clears it. When no card is up this is a no-op
  /// and the failure comes back out on the pill, which is the right split:
  /// `isReviewing` is exactly "a card exists".
  func setError(_ message: String?)
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
  /// The card's editable text and its two decisions. Internal rather than
  /// private: the buttons and the key monitor both act through it, so a test
  /// that drives it is driving exactly what the owner drives.
  let model = DictationReviewModel()
  private var keyMonitor: Any?
  /// The review currently on screen. Taken — not merely read — the instant a
  /// decision lands, which is what makes Apply-then-close fire exactly one
  /// callback.
  private var pending: DictationReviewRequest?

  /// What the card's Finish button does. Owned by the controller — the presenter
  /// knows only that the owner asked for the session to stop.
  var onFinishRecording: (() -> Void)?

  /// The owner's glass tint weight. Applied to the panel the moment it is set —
  /// a card that is already up retints under the Settings slider — and again to
  /// every panel this presenter shows, including a recreated one.
  var glassTintAlpha: Double = GlassTint.standard {
    didSet { panel?.setGlassTintAlpha(glassTintAlpha) }
  }

  var isPresenting: Bool { pending != nil }

  var editorText: String? { pending == nil ? nil : model.text }

  @discardableResult
  func replaceEditorText(_ text: String) -> Bool {
    guard pending != nil else { return false }
    model.text = text
    return true
  }

  func setListening(_ listening: Bool) {
    guard pending != nil else { return }
    model.isListening = listening
    // The draft belongs to the session, so it goes when the session does — the
    // controller clears it too, and this is the backstop for a card that
    // stopped listening by some other route.
    //
    // Nothing here resizes the panel any more: the draft is drawn inside the
    // editor, which is a box of fixed height whatever is in it. The card's
    // height is decided once, when it is presented, which is what a surface the
    // owner is typing into is owed.
    if !listening { model.draft = .empty }
  }

  func setDraft(_ draft: HUDDraft) {
    guard pending != nil else { return }
    model.draft = draft
  }

  func setError(_ message: String?) {
    guard pending != nil else { return }
    model.errorMessage = message
  }

  @discardableResult
  func present(_ request: DictationReviewRequest) -> Bool {
    // A second present without a decision would strand the first session's
    // text: close it out as a discard so nothing of it is ever inserted.
    dismiss()

    pending = request
    model.text = request.text
    model.isListening = false
    model.draft = .empty
    model.errorMessage = nil
    model.onApply = { [weak self] text in self?.finish(.apply(text)) }
    model.onDiscard = { [weak self] in self?.finish(.discard) }
    // Not a decision, so it does not go through `finish`: Finish ends the
    // dictation session and leaves the card exactly where it is, waiting for the
    // decision it is now able to offer.
    model.onFinishRecording = { [weak self] in self?.onFinishRecording?() }

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
    // The card is dragged by its title row, and a dropped position is
    // remembered. Wired here rather than in the model's init because it is the
    // *panel* that gets moved, and a recreated panel has to take the callbacks
    // over from the one it replaced.
    model.onDragChanged = { [weak panel] in panel?.dragChanged() }
    model.onDragEnded = { [weak panel] in panel?.dragEnded() }
    // Here for the same reason as the drag callbacks: a recreated panel is a
    // fresh `GlassBackingView` and starts on the built-in default, so the
    // owner's weight has to be re-applied rather than assumed to have survived.
    panel.setGlassTintAlpha(glassTintAlpha)
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
    model.isListening = false
    model.draft = .empty
    model.errorMessage = nil
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
  ///
  /// Both cases go through `model.primaryAction()` / `model.discard()` — the
  /// *same* call the card's two buttons make — rather than reaching into
  /// `finish` directly. There is then exactly one expression of what ⌘↩ means
  /// (Finish while a session is recording, Apply once one is not), so the
  /// shortcut and the button cannot drift apart. They did not differ in code
  /// when ⌘↩ was dropping text (that was the physically-held ⌘ — see
  /// `ModifierClearance`), and this is what keeps that true.
  private func installKeyMonitor(for panel: NSPanel) {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
      guard let self, let panel, event.window === panel else { return event }
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      switch event.keyCode {
      case 53: // Escape
        self.model.discard()
        return nil
      case 36 where flags.contains(.command): // Return
        self.model.primaryAction()
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
  /// True while a continuation session is recording into this card.
  ///
  /// One decision per review, and it is about the whole batch — so while more
  /// of that batch is still being spoken there is nothing to decide about yet.
  @Published var isListening: Bool = false
  /// The session's live draft, rendered as a dimmed suffix *inside* the editor
  /// while it records.
  ///
  /// Separate from `text` on purpose and permanently: `text` is the owner's
  /// buffer and a mode whose whole point is to capture their corrections may
  /// not write into it behind them. The finished, polished text is appended
  /// once, at stop, by the controller. Drawing the two in one text box is what
  /// the owner asked for; keeping them two *values* is what makes it legal.
  @Published var draft: HUDDraft = .empty
  /// A session failure, shown in the card's status line.
  ///
  /// Occupies the slot the footer caption already had rather than adding a row:
  /// the card's height is decided once, when it is presented, and a status that
  /// can appear at any moment must not be able to resize a card the owner is
  /// typing into. An error IS a status, so it takes the status line.
  @Published var errorMessage: String?

  var onApply: ((String) -> Void)?
  var onDiscard: (() -> Void)?
  /// Ends the dictation session recording into this card. Installed by the
  /// presenter, which forwards it to the controller — the model never learns
  /// what stopping a session involves.
  var onFinishRecording: (() -> Void)?

  /// Move the card with the pointer (title-row drag), and remember where it was
  /// dropped. Installed by the presenter; nil in a preview or a bare unit test.
  var onDragChanged: (() -> Void)?
  var onDragEnded: (() -> Void)?

  /// Apply and Discard, refused while a continuation is recording.
  ///
  /// The gate lives here rather than in the buttons because the key monitor is
  /// the other caller, and the ⌘↩ bug was expensive enough to be worth having
  /// exactly one place where "what Apply means" is written down. The buttons
  /// are disabled too — this is the backstop, and the beep is what a keystroke
  /// that has been swallowed owes the person who typed it.
  func apply() {
    guard !isListening else { return NSSound.beep() }
    onApply?(text)
  }

  func discard() {
    guard !isListening else { return NSSound.beep() }
    onDiscard?()
  }

  /// Stop the session recording into this card, from the card itself.
  ///
  /// Added 2026-08-03 on owner feedback: the card used to show two greyed-out
  /// buttons for the whole time the microphone was open, and the only way to
  /// stop was the trigger key. It is deliberately *not* a decision — nothing is
  /// applied, nothing is discarded, and the card stays exactly where it is. What
  /// it buys is the state in which a decision becomes possible at all.
  func finishRecording() {
    guard isListening else { return NSSound.beep() }
    onFinishRecording?()
  }

  /// What the card's prominent button and ⌘↩ do, which is a function of the one
  /// flag that distinguishes the card's two states.
  ///
  /// One expression of it, called by both routes, for the reason `apply()` is:
  /// the ⌘↩ bug cost enough that "what the primary action means" is written down
  /// exactly once. While recording it is Finish; otherwise it is Apply.
  func primaryAction() {
    isListening ? finishRecording() : apply()
  }
}

// MARK: - DictationReviewPanel

/// The one surface a `.review` session has, for the whole of its life.
///
/// It goes up when the hotkey goes down — empty, in the recording state — and
/// comes down on ⌘↩ or Escape. In between it is *the same NSPanel* through
/// every state change: recording (header mic dot + "Listening…", the live-draft
/// block, decisions refused), deciding (the polished text in the editor,
/// Discard/Apply), and recording again for a continuation. No swap, no second
/// window, and no HUD pill anywhere in the mode — which is the whole point of
/// merging the two (owner, 2026-08-03).
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
  /// The card's Liquid Glass plate, with the hosting view above it.
  ///
  /// AppKit rather than `.glassEffect`, for the reason `GlassBackingView`
  /// documents: a SwiftUI glass modifier in a transparent panel refracts only its
  /// own hierarchy and reads as a flat blur. Plain `GlassBackingView` rather than
  /// the HUD's `HUDDragView` subclass — this card is dragged by one row and its
  /// editor must keep text selection everywhere else, so nothing here may claim
  /// every point.
  private let backingView = GlassBackingView(inset: DictationReviewView.shadowMargin)

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
    // which turns it into a dark rectangle behind a rounded card. The glass plate
    // is inset by `DictationReviewView.shadowMargin` and its own treatment falls
    // into that margin, exactly as the HUD pill's does.
    hasShadow = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    // The title row is the drag handle (see `DictationReviewView.titleRow`), and
    // it is the ONLY mover: AppKit's background drag reports nothing, and "the
    // owner chose this position" is precisely the fact that has to be
    // remembered. Two movers on one frame is also how the HUD's drag was got
    // wrong the first time. Leaving it off has a second benefit here that the
    // HUD does not have — this card contains a text view, and a drag inside it
    // must select text.
    isMovableByWindowBackground = false
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

    backingView.glassCornerRadius = DictationReviewView.cornerRadius
    backingView.setContent(hostingView)
    contentView = backingView
    pinnedCardTopLeft = ReviewPositionStore.load()
  }

  /// Retint the card's glass. Clamped here rather than trusted, because this is
  /// the boundary a stored value crosses to reach the window server.
  func setGlassTintAlpha(_ alpha: Double) {
    backingView.tintAlpha = GlassTint.clamped(alpha)
  }

  // MARK: - Dragging

  /// Where the owner dragged the card, as the CARD rect's **top-left** point in
  /// screen coordinates — nil until they drag one.
  ///
  /// Top-left rather than the window origin (which is the bottom-left, and
  /// includes the transparent shadow margin) for the reason the HUD stores a
  /// bottom-center: it has to be the corner the card is read from. The card's
  /// height is now fixed for its whole life — the live draft is drawn inside the
  /// editor rather than in a block that grows the panel — so the top-left is
  /// simply where the owner put it, and stays exact.
  private(set) var pinnedCardTopLeft: CGPoint?

  /// Pointer and window origin at the moment the drag began.
  private var dragAnchor: (mouse: NSPoint, origin: NSPoint)?

  /// Follow the pointer. Measured against `NSEvent.mouseLocation` — absolute
  /// screen coordinates — and never against the gesture's own translation: the
  /// gesture's coordinate space is anchored to a window this very call is
  /// moving, so a translation-driven drag reports ~zero and the card sticks.
  func dragChanged() {
    if dragAnchor == nil {
      dragAnchor = (mouse: NSEvent.mouseLocation, origin: frame.origin)
    }
    guard let anchor = dragAnchor else { return }
    let now = NSEvent.mouseLocation
    setFrameOrigin(
      NSPoint(
        x: anchor.origin.x + now.x - anchor.mouse.x,
        y: anchor.origin.y + now.y - anchor.mouse.y
      )
    )
  }

  func dragEnded() {
    defer { dragAnchor = nil }
    guard dragAnchor != nil else { return }
    let margin = DictationReviewView.shadowMargin
    let card = frame.insetBy(dx: margin, dy: margin)
    let point = CGPoint(x: card.minX, y: card.maxY)
    pinnedCardTopLeft = point
    ReviewPositionStore.save(point)
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

    // The owner's own position outranks the anchor window, and is validated
    // rather than trusted every single time: the display it was recorded on may
    // be gone or smaller, and a card restored off-screen is a session's whole
    // output invisible. A point no current screen can host is DROPPED and the
    // automatic placement below is the self-heal — clamping it onto whatever
    // display is left would call an arbitrary point the owner's choice.
    if let pinned = pinnedCardTopLeft {
      if let topLeft = ReviewPanelLayout.validatedTopLeft(
        pinned,
        cardSize: card,
        visibleFrames: NSScreen.screens.map(\.visibleFrame)
      ) {
        setFrameOrigin(NSPoint(x: topLeft.x - margin, y: topLeft.y - card.height - margin))
        return
      }
      pinnedCardTopLeft = nil
      ReviewPositionStore.clear()
    }

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

// MARK: - Review position

/// Where the owner dragged the review card, across launches.
///
/// **Its own key, deliberately not `HUDPositionStore`'s.** The mechanism is
/// shared — validate-or-drop on restore, the owner's point outranks the
/// automatic placement — and the stored value is not, because the two surfaces
/// pin different edges for different reasons. `HUDPositionStore` holds the pill
/// rect's *bottom-center*: the bottom edge is what the HUD's upward growth pins,
/// and the horizontal centre is the only x that survives a switch between a
/// 200pt pill and a 600pt prompter. This card is a constant-size surface, so its
/// meaningful anchor is simply its *top-left*. Sharing one
/// point would mean dragging one surface moved the other, converted through an
/// anchor that means nothing on the far side. (The pill still grows; this card
/// no longer does, which only makes its top-left the more exact anchor.)
///
/// Backed by `DictationSettingsStore.defaults`, which is a private wiped suite
/// under XCTest: a test that drags the card must not move the owner's real one.
enum ReviewPositionStore {
  private static let key = "com.xiafawu.nota.dictationReviewPosition"

  static func load() -> CGPoint? {
    guard let pair = DictationSettingsStore.defaults.array(forKey: key) as? [Double],
          pair.count == 2,
          pair.allSatisfy({ $0.isFinite })
    else { return nil }
    return CGPoint(x: pair[0], y: pair[1])
  }

  static func save(_ point: CGPoint) {
    guard point.x.isFinite, point.y.isFinite else { return }
    DictationSettingsStore.defaults.set([point.x, point.y], forKey: key)
  }

  static func clear() {
    DictationSettingsStore.defaults.removeObject(forKey: key)
  }
}

/// Where the review card sits, as arithmetic — no NSScreen, no window server.
enum ReviewPanelLayout {
  /// Smallest gap kept between the card and the edges of the visible screen.
  static let screenInset: CGFloat = 8

  /// The owner's dragged top-left, made safe to restore, or nil when no current
  /// screen can host it.
  ///
  /// Returning nil is the self-heal: the caller drops the stored position and
  /// falls back to the automatic placement under the focused window. A point a
  /// screen *does* hold is still clamped, because a screen can shrink
  /// (resolution change, menu bar, Dock) under a position that used to fit —
  /// and because the whole card, not just its corner, has to stay on it.
  static func validatedTopLeft(
    _ point: CGPoint,
    cardSize: CGSize,
    visibleFrames: [NSRect]
  ) -> CGPoint? {
    guard let visible = visibleFrames.first(where: { $0.contains(point) }) else { return nil }
    guard cardSize.width + screenInset * 2 <= visible.width,
          cardSize.height + screenInset * 2 <= visible.height
    else { return nil }

    let x = min(
      max(point.x, visible.minX + screenInset),
      visible.maxX - screenInset - cardSize.width
    )
    let y = min(
      max(point.y, visible.minY + screenInset + cardSize.height),
      visible.maxY - screenInset
    )
    return CGPoint(x: x, y: y)
  }
}

// MARK: - DictationReviewView

/// The card: one pane of Liquid Glass and no other chrome — the same grammar as
/// the HUD pill it replaces on screen.
///
/// **The text is on top and the chrome is along the bottom** (owner, 2026-08-03:
/// "the review, dictation, listening, number of words stuff should be along the
/// bottom rows, and the text grows upwards"). Two consequences worth stating,
/// because both are the reason the inversion is more than a reordering:
///
/// - The editor is **bottom-aligned**, so a short batch sits against the chrome
///   rather than floating at the top of an empty box, and each new sentence
///   pushes the earlier ones up. That is the same reading line the HUD pill and
///   the prompter pin — the newest words nearest the fixed edge — and here the
///   fixed edge is the row the owner is about to press a button in.
/// - The **bottom meta row is the drag handle** now, for the reason the title row
///   was: it is the one part of the card that is neither an editor nor a button,
///   so a drag on it can never be a text selection or a mis-click on Apply.
struct DictationReviewView: View {
  @ObservedObject var model: DictationReviewModel

  /// Transparent margin around the card: the glass plate's inset, and the room
  /// its shadow falls into. A window cannot draw outside its own frame, so the
  /// room has to come from inside.
  static let shadowMargin: CGFloat = 24
  static let minCardWidth: CGFloat = 520
  static let minCardHeight: CGFloat = 200
  static let maxCardHeight: CGFloat = 520

  /// Gap between the card's rows.
  static let rowSpacing: CGFloat = 12
  /// The editor's height — fixed, and the reason the card's is.
  ///
  /// It was a `minHeight` while the card had a separate draft block to grow for.
  /// With the draft drawn *inside* the editor there is nothing left that can
  /// change the card's size, which is what a surface the owner types into is
  /// owed: the panel is sized once, when it is presented, and never resizes
  /// under their caret.
  static let editorHeight: CGFloat = 116

  /// Corner curvature of the card. Internal because the glass plate underneath
  /// is an AppKit view and has to be told the same number
  /// (`DictationReviewPanel.init`).
  static let cornerRadius: CGFloat = 16

  var body: some View {
    // Text first, chrome last — and both chrome rows are pinned to the bottom by
    // being last in a `VStack` whose only flexible row is the editor above them.
    VStack(alignment: .leading, spacing: Self.rowSpacing) {
      editor
      metaRow
      controlsRow
    }
    .padding(18)
    .frame(
      minWidth: Self.minCardWidth,
      minHeight: Self.minCardHeight,
      alignment: .bottomLeading
    )
    // No fill, no hairline, no SwiftUI shadow: the card's body is an
    // `NSGlassEffectView` laid out at exactly this rect by `GlassBackingView`.
    // A SwiftUI glass modifier here would refract only this hierarchy — a flat
    // blur — and a flat fill painted on top of the plate would simply be the old
    // card again, drawn over the material that replaced it.
    .environment(\.colorScheme, .dark)
    .padding(Self.shadowMargin)
  }

  /// The card's name, a mic dot while a session is recording, and the word
  /// count — the first of the two bottom rows.
  ///
  /// The dot is the card borrowing the HUD pill's own grammar rather than
  /// growing a second visual language: the pill's listening state is a filled
  /// accent circle, and this is that circle. Nothing else moves — the card must
  /// not resize under the owner's cursor while they are mid-edit.
  private var metaRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text("Review dictation")
        .font(.headline)
      if model.isListening {
        HStack(spacing: 5) {
          Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
          Text("Listening…")
            .font(.caption)
        }
        .foregroundStyle(.secondary)
        .transition(.opacity)
      }
      Spacer(minLength: 12)
      Text(wordCountLabel)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    // This row is the card's drag handle — the one part of it that is neither an
    // editor nor a button, so a drag here can never be a text selection or a
    // mis-click on Apply. It moved to the bottom with the rest of the chrome and
    // is still the only mover: `isMovableByWindowBackground` stays off, because
    // AppKit's background drag reports nothing and "the owner chose this
    // position" is exactly the fact `ReviewPositionStore` has to record.
    // `contentShape` is what makes the `Spacer` grabbable too; without it the
    // handle would be the two labels alone.
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 2)
        .onChanged { _ in model.onDragChanged?() }
        .onEnded { _ in model.onDragEnded?() }
    )
  }

  private var wordCountLabel: String {
    let count = DictationReview.wordCount(model.text)
    return count == 1 ? "1 word" : "\(count) words"
  }

  /// **One text box for the whole card** (owner, 2026-08-03: "I'm not sure why
  /// we have review dictation and a preview… maybe we could merge those 2
  /// things together, into one text box").
  ///
  /// It holds the owner's buffer and, while a session is recording, the words
  /// coming in — drawn onto the end of that buffer, finalized at full opacity
  /// and the volatile tail dimmed to 55%, the prompter's treatment. That suffix
  /// is **display only**: it is never in `model.text`, it is never editable, and
  /// the finished polished text still reaches the buffer exactly once, at stop,
  /// through `DictationReview.appended`. What the merge changed is where the
  /// draft is drawn; not one thing about what it is.
  ///
  /// It is an `NSTextView` rather than SwiftUI's `TextEditor` because
  /// `TextEditor` binds a plain `String` and cannot draw part of its content in
  /// another colour. Keeping the *same* view through both states is the point of
  /// having merged them: the recording state and the deciding state differ by one
  /// flag (`isEditable`), so there is no second layout to keep in step and no
  /// text view rebuilt under the owner's caret.
  ///
  /// Borderless by construction: no bezel, no scroll background, no focus ring
  /// box. The card is the container; a second box inside it is what made the
  /// panel read as a bare text input.
  ///
  /// Since the inversion it is also **bottom-aligned** — see
  /// `ReviewEditorLayout` — so the batch reads from the chrome upward and the
  /// incoming words sit right against the row the owner decides in.
  private var editor: some View {
    ReviewEditor(
      text: $model.text,
      draft: model.isListening ? model.draft : nil,
      isEditable: !model.isListening
    )
    .frame(height: Self.editorHeight)
  }

  /// Status line and the two decisions — the last row on the card, and the edge
  /// the text above it grows away from.
  private var controlsRow: some View {
    HStack(spacing: 10) {
      statusLine
      Spacer(minLength: 12)

      Button { model.discard() } label: {
        ReviewButtonLabel(title: "Discard", shortcut: "esc")
      }
      .buttonStyle(ReviewButtonStyle(prominent: false))
      .keyboardShortcut(.cancelAction)
      .disabled(model.isListening)

      // The prominent slot is Finish while a session is recording and Apply once
      // one is not — one button, two jobs, because they are the same gesture at
      // two points in the batch's life: "I am done saying this."
      //
      // A disabled Apply was what stood here for the whole time the microphone
      // was open, which left the card with two greyed-out buttons and the trigger
      // key as the only way to stop (owner, 2026-08-03). Discard stays disabled:
      // throwing the batch away IS a decision, and the decision is about a batch
      // that is still being spoken.
      Button { model.primaryAction() } label: {
        ReviewButtonLabel(
          title: model.isListening ? "Finish" : "Apply",
          shortcut: "⌘↩"
        )
      }
      .buttonStyle(ReviewButtonStyle(prominent: true))
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(
        !model.isListening
          && model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      )
    }
  }

  /// One line, three things it can say — and a failure outranks the other two.
  ///
  /// The card is a review session's only surface, so an error has to land here
  /// or nowhere. It takes the slot the caption already occupied rather than a
  /// row of its own: the card's height is fixed when it is presented, and a
  /// message that can arrive at any moment must not resize a card the owner is
  /// mid-edit in. Held to one line for the same reason, with the full text on
  /// the tooltip.
  @ViewBuilder
  private var statusLine: some View {
    if let error = model.errorMessage, !error.isEmpty {
      HStack(spacing: 5) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.caption)
        Text(error)
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .foregroundStyle(Color.red.opacity(0.9))
      .help(error)
    } else {
      Text(footerCaption)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// While the microphone is open the card says what it is waiting for. Both
  /// decisions are about the whole batch, and the batch is not finished.
  ///
  /// The empty-and-listening wording is the FIRST session's: the card now opens
  /// the moment the hotkey goes down, before a word has been recognized, and
  /// "this will be added" would be describing an addition to nothing. Neither
  /// says "when you stop" any more — Finish is on the card, so the caption names
  /// the thing the owner can actually press.
  private var footerCaption: String {
    guard model.isListening else { return "Nothing is inserted until you apply." }
    return model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Listening — press Finish when you're done."
      : "Keep talking — this will be added when you finish."
  }
}

// MARK: - ReviewEditor

/// The card's one text box: the owner's buffer, plus the live draft drawn onto
/// the end of it while a session records.
///
/// An `NSTextView` because the merge needs two colours in one box and
/// `TextEditor` binds a plain `String`. Three rules it exists to keep:
///
/// 1. **The draft is a suffix, never content.** `text` is the owner's buffer and
///    the only thing that is ever read back out; the draft occupies the range
///    past its end and is replaced wholesale on every tick. Nothing the
///    recognizer says can reach the binding — the finished, polished text is
///    appended once, at stop, by the controller.
/// 2. **Only the suffix is rewritten per tick.** The feed arrives many times a
///    second. Replacing the whole storage would re-lay-out the owner's buffer on
///    every one of them; replacing `bufferLength..<end` leaves it alone. The
///    draft itself is bounded by `ReviewDraftMetrics.windowed` before it gets
///    here.
/// 3. **The caret survives.** The buffer is written only when it actually
///    differs from what this view last put there, so a keystroke that flows
///    binding → `updateNSView` does not reset the selection the owner is typing
///    at.
/// 4. **Short text sits at the BOTTOM of the box.** The chrome is along the
///    bottom of the card and the text grows upward into the empty space above it
///    (owner, 2026-08-03). See `ReviewEditorLayout`.
struct ReviewEditor: NSViewRepresentable {
  @Binding var text: String
  /// The live draft, or nil when no session is recording into this card.
  let draft: HUDDraft?
  let isEditable: Bool

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> ReviewScrollView {
    let scrollView = ReviewScrollView()
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.autohidesScrollers = true

    // Bottom-aligned: a batch shorter than the box rests on its bottom edge, so
    // the text grows up toward the chrome instead of away from it.
    let textView = BottomAlignedTextView()
    textView.delegate = context.coordinator
    textView.drawsBackground = false
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = Self.font
    textView.textColor = .white
    textView.insertionPointColor = .white
    textView.textContainerInset = NSSize(width: 0, height: 2)
    // Everything macOS would otherwise do TO this text, off.
    //
    // Two independent reasons, and the first is the serious one. The box holds
    // text a recognizer produced and a dictionary already corrected — smart
    // quotes, dash substitution and autocorrect would silently rewrite it
    // between the pipeline and Apply, and the owner would be endorsing a
    // spelling nobody chose. (The immediate path injects into someone else's
    // field and was never exposed to this; the review card is Nota's own text
    // view, so it is Nota's job to turn them off.) The second is that inline
    // prediction attaches a remote view service to the panel, which is noise on
    // a nonactivating card and made the test host raise on order-on-screen.
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextCompletionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.inlinePredictionType = .no
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true

    scrollView.documentView = textView
    context.coordinator.textView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: ReviewScrollView, context: Context) {
    context.coordinator.parent = self
    defer { Self.realignToBottom(scrollView) }
    guard let textView = context.coordinator.textView,
          let storage = textView.textStorage
    else { return }

    textView.isEditable = isEditable

    // The owner's buffer, only when it really changed. `updateNSView` runs on
    // every keystroke that flows back through the binding, and an unconditional
    // write would drop the caret to the start of the line on each one.
    let buffer = text
    if buffer != context.coordinator.buffer {
      let previous = context.coordinator.buffer as NSString
      storage.replaceCharacters(
        in: NSRange(location: 0, length: previous.length),
        with: NSAttributedString(string: buffer, attributes: Self.bufferAttributes)
      )
      context.coordinator.buffer = buffer
    }

    let suffix = Self.attributedDraft(draft, after: context.coordinator.buffer)
    if suffix != context.coordinator.suffix {
      let bufferLength = (context.coordinator.buffer as NSString).length
      storage.replaceCharacters(
        in: NSRange(location: bufferLength, length: storage.length - bufferLength),
        with: suffix
      )
      context.coordinator.suffix = suffix
      // The newest words are the only reason the suffix is drawn, and the box is
      // a fixed height — so it follows the tail rather than leaving the owner
      // looking at the top of their own buffer.
      if suffix.length > 0 { textView.scrollToEndOfDocument(nil) }
    }
  }

  /// Re-ask for the bottom alignment.
  ///
  /// `textContainerOrigin` is read while drawing, and the amount it shifts by
  /// changes whenever the text's height does — but an edit invalidates only the
  /// range it touched, and a shift moves every glyph in the view. So the whole
  /// box is invalidated after a content change, and again from
  /// `ReviewScrollView.layout`, which is the first moment the box's own height
  /// is known.
  static func realignToBottom(_ scrollView: ReviewScrollView) {
    scrollView.documentView?.needsDisplay = true
  }

  private static var font: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }

  private static var bufferAttributes: [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: NSColor.white]
  }

  /// Finalized text at (near) full opacity, the volatile tail dimmed — the
  /// prompter's treatment, so "what the recognizer has committed to" reads the
  /// same wherever the owner sees it.
  ///
  /// The separator rides on the finalized run, via `ReviewDraftMetrics.runs`,
  /// and one more joins the suffix to the buffer: the buffer is what this draft
  /// will be appended to at stop, and it must read now the way it will read then.
  static func attributedDraft(_ draft: HUDDraft?, after buffer: String = "") -> NSAttributedString {
    guard let draft, !draft.isEmpty else { return NSAttributedString() }
    let window = ReviewDraftMetrics.windowed(
      finalized: draft.finalized,
      volatileTail: draft.volatileTail
    )
    let runs = ReviewDraftMetrics.runs(
      finalized: window.finalized,
      volatileTail: window.volatileTail
    )
    let result = NSMutableAttributedString()
    let lead = StreamingDelivery.joiningSeparator(
      buffer,
      runs.finalized.isEmpty ? runs.volatileTail : runs.finalized
    )
    if !runs.finalized.isEmpty || !lead.isEmpty {
      result.append(NSAttributedString(
        string: lead + runs.finalized,
        attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
      ))
    }
    if !runs.volatileTail.isEmpty {
      result.append(NSAttributedString(
        string: runs.volatileTail,
        attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
      ))
    }
    return result
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ReviewEditor
    weak var textView: NSTextView?
    /// What this view last wrote as the owner's buffer, so an unchanged binding
    /// is not written back over their caret.
    var buffer: String = ""
    /// What this view last wrote as the draft suffix.
    var suffix = NSAttributedString()

    init(_ parent: ReviewEditor) {
      self.parent = parent
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      // The box is read-only for exactly as long as a draft suffix exists, so a
      // change that reaches here can only be the owner editing their own buffer
      // — and the whole string IS that buffer. Refusing outright when a suffix
      // is up is the backstop: nothing the recognizer drew may ever be read back
      // as if the owner had typed it.
      guard suffix.length == 0 else { return }
      buffer = textView.string
      parent.text = textView.string
    }
  }
}

// MARK: - ReviewScrollView

/// The editor's scroll view, with one addition: it re-asks for the bottom
/// alignment once it has been laid out.
///
/// The alignment depends on the box's height, and the box's height is known only
/// after AppKit has laid the panel out — which happens after the first
/// `updateNSView`. Without this a card presented with a short batch would draw it
/// at the top of the box once and correct itself only on the next keystroke.
final class ReviewScrollView: NSScrollView {
  override func layout() {
    super.layout()
    ReviewEditor.realignToBottom(self)
  }
}

// MARK: - BottomAlignedTextView

/// A text view that draws a short batch against the BOTTOM of its box.
///
/// The card's chrome is along its bottom and the text grows upward into the
/// space above it (owner, 2026-08-03) — the reading line the HUD pill and the
/// prompter already pin: the newest words nearest the edge that does not move.
///
/// `textContainerOrigin` is the hook, and the two obvious alternatives were both
/// tried and both measured wrong:
///
/// - `NSScrollView.contentInsets` moves the scrollable area, not the document. A
///   document no taller than its clip view is pinned to the clip's leading edge
///   by `constrainBoundsRect` whatever the inset says, so the text did not move.
/// - Letting the text view shrink to its text (`minSize = .zero`) and
///   bottom-aligning it in a custom clip view does not survive: the scroll view
///   re-imposes the clip's size as `minSize` on every tile, so the document is
///   always exactly as tall as the box and there is nothing left to align.
///
/// `textContainerInset` is not a candidate at all — it is symmetric, padding the
/// bottom by whatever it pads the top, and the ask is asymmetric.
///
/// Shifting the container's ORIGIN moves the glyphs, the caret and the hit
/// testing together, which is why a click still puts the caret where the owner
/// pointed. Past the point where the text fills the box the shift is zero and the
/// box behaves exactly as it did before the inversion.
final class BottomAlignedTextView: NSTextView {
  override var textContainerOrigin: NSPoint {
    var origin = super.textContainerOrigin
    origin.y += ReviewEditorLayout.topInset(
      contentHeight: usedContentHeight,
      visibleHeight: bounds.height
    )
    return origin
  }

  /// How tall the text is, measured off the attributed storage rather than
  /// asked of a layout manager.
  ///
  /// Deliberately not `NSTextLayoutManager.usageBoundsForTextContainer`: this
  /// getter is read *during* layout and drawing, and reaching back into the
  /// layout that is asking is how a getter like this recurses. `boundingRect` is
  /// the same arithmetic the prompter's line count already trusts, and the width
  /// it needs is the container's, which is fixed by `widthTracksTextView`.
  private var usedContentHeight: CGFloat {
    guard let storage = textStorage, storage.length > 0 else { return 0 }
    let width = textContainer.map { $0.size.width - $0.lineFragmentPadding * 2 }
      ?? bounds.width
    guard width > 0 else { return 0 }
    let height = storage.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading]
    ).height
    return height + textContainerInset.height * 2
  }
}

// MARK: - ReviewEditorLayout

/// Where the batch sits inside the editor's box, as arithmetic.
enum ReviewEditorLayout {
  /// Empty space ABOVE the text when it rests on the box's bottom edge.
  ///
  /// Zero once the text is at least as tall as the box, which is what keeps this
  /// from fighting the scrolling: past that point there is no empty space to
  /// distribute and the box behaves exactly as it did before the inversion.
  static func topInset(contentHeight: CGFloat, visibleHeight: CGFloat) -> CGFloat {
    max(0, visibleHeight - max(contentHeight, 0))
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
