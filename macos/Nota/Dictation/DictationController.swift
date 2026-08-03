import AppKit
import Foundation
import os

// MARK: - DictationSessionPlan

/// What a session's delivery mode and engine ask of the recognizer.
///
/// Pure and separate from the controller so the claim that matters can be
/// asserted without a microphone: **review runs the streaming recognizer for
/// its live rough draft but never delivers anything mid-session.** The two are
/// independent answers — one is about what the HUD can show while the owner
/// talks, the other about what reaches their document — and collapsing them
/// into a single `wantsStreaming` flag is what left review mode with a silent
/// pill.
struct DictationSessionPlan: Equatable {
  /// Build the recognizer in streaming mode: a volatile tail for the pill's
  /// rough draft, plus finalized results as deltas.
  let wantsLiveDraft: Bool
  /// Build a delivery queue and type each sentence in as it is recognized.
  let deliversMidSession: Bool
  /// Capture the injection target when the hotkey goes down.
  let capturesTarget: Bool

  static func make(mode: DeliveryMode, engine: EngineChoice) -> DictationSessionPlan {
    // Apple's analyzer only streams when asked (streaming/review); AssemblyAI
    // realtime streams partial Turns in every mode, so its live HUD draft is
    // available even for batch delivery — the pill previews what is being said
    // while the text still lands once, at release. Mid-session delivery stays
    // Apple-only: AssemblyAI has no sentence deltas, so its streaming sessions
    // fall back to batch delivery.
    let wantsDraft: Bool
    switch engine {
    case .apple:
      wantsDraft = mode == .streaming || mode == .review
    case .assemblyAIRealtime:
      wantsDraft = true
    }
    return DictationSessionPlan(
      wantsLiveDraft: wantsDraft,
      // Streaming appends into whatever had focus when the hotkey went down and
      // keeps appending there for the whole session. Review appends nothing at
      // all until the owner says so.
      deliversMidSession: mode == .streaming && engine == .apple,
      // Review captures the same target for the opposite reason streaming does:
      // nothing is delivered during the session, and by the time the owner
      // applies, the session that recognized the audio is long over. Engine
      // independent — the pid is needed however the audio was recognized.
      capturesTarget: mode == .review || (mode == .streaming && engine == .apple)
    )
  }
}

@MainActor
final class DictationController: ObservableObject {
  @Published private(set) var state: DictationState = .disabled(reason: "Checking permissions…") {
    didSet { publishReviewError() }
  }
  @Published private(set) var lastCaptureDiagnostics: CaptureDiagnostics?
  @Published private(set) var lastLatency: TimeInterval?
  @Published private(set) var lastHypothesis: String?
  @Published private(set) var lastProcessedText: String?

  /// The last rules-only result before polish (for diagnostics).
  @Published private(set) var lastRulesResult: String?
  /// Non-nil when polish produced a different result than rules.
  @Published private(set) var lastPolishResult: String?
  /// Set when polish was skipped or failed.
  @Published private(set) var lastPolishWarning: String?
  /// True while a polish LLM call is in flight.
  @Published private(set) var isPolishInProgress: Bool = false
  /// Completed dictations retained locally for recovery when insertion is
  /// refused, unsupported, or otherwise cannot be confirmed.
  @Published private(set) var dictationHistory: [DictationHistoryEntry] = []
  @Published private(set) var historyNotice: String?
  var dictationHistoryRetentionLimit: Int { historyStore.retentionLimit }
  /// The recognizer's un-finalized tail — the rough draft the HUD shows.
  ///
  /// Fed by every session that runs the streaming recognizer, which is both of
  /// the non-default delivery modes: streaming is already typing the finalized
  /// text in, and review shows the draft because the pill is the *only* thing
  /// on screen until the panel opens. Always empty in `.immediate`.
  @Published private(set) var roughDraft: String = ""
  /// True while the review panel holds this session's text and nothing has
  /// been inserted. The HUD reads it to stand down — the panel is the feedback.
  @Published private(set) var isReviewing = false
  let permissions: PermissionsCoordinator
  let capture: MicCapture

  /// The last secure-field refusal message from the injector (nonfatal).
  var lastSecureFieldNotice: String? {
    injector.lastSecureFieldNotice
  }

  /// Current settings — accessible by views for display.
  private(set) var settings: DictationSettings {
    didSet {
      // Manual publish: `settings` is not @Published, but HUDController
      // subscribes to objectWillChange to react to showHUD toggle changes.
      objectWillChange.send()
      DictationSettingsStore.save(settings)
      applySettings()
    }
  }

  private let hotkeyMonitor: HotkeyMonitor
  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.controller")
  private let historyStore: DictationHistoryStore
  private var hasStarted = false
  private var launchObserver: NSObjectProtocol?
  private var activationObserver: NSObjectProtocol?

  // P2: speech + injection session state
  private var speechStream: (any SpeechStream)?
  private var holdBeganAt: Date?
  private var isSessionPending = false
  private let injector = TextInjector()

  /// What the user was looking at when this session began (plan 02). Captured
  /// at start so the AX round-trip hides under the first syllable.
  private(set) var sessionContext: ContextSnapshot = .empty
  /// Privacy settings are snapshotted with the session so changing Settings
  /// mid-dictation cannot change what that session sends to a model.
  private var sessionUsesScreenContext = false
  private var sessionUsesScreenCaptureFallback = false
  /// Dictionary snapshot for this session, read once at start so mid-session
  /// edits can never change the vocabulary out from under the pipeline.
  private(set) var sessionDictionary: [DictionaryTerm] = []

  // MARK: - Streaming delivery session state (plan 04)

  /// True only once the recognizer has confirmed it will report finalized
  /// segments mid-session AND the session has somewhere safe to append to.
  private var isStreamingSession = false
  /// True once the recognizer has confirmed it reports a volatile tail — the
  /// rough draft — whether or not this session delivers anything mid-session.
  ///
  /// Strictly weaker than `isStreamingSession`: a review session sets this and
  /// not that, which is exactly the difference between "the pill shows what you
  /// are saying" and "the text is already in your document".
  private var isLiveDraftSession = false
  /// Where this session's text goes, captured when the hotkey went down.
  ///
  /// Streaming needs it because delivery happens while the user may already be
  /// somewhere else; review needs it because the panel holds key focus, so a
  /// capture at Apply time would read the panel's own editor as the target.
  private var sessionTarget: FocusedTarget?
  private var segmenter = SentenceSegmenter()
  private var deliveryQueue: StreamingDeliveryQueue?
  private var streamingHistoryID: UUID?
  private var hypothesisTask: Task<Void, Never>?
  /// Everything the recognizer has finalized this session.
  ///
  /// Published, not private: the prompter HUD style renders it in full next to
  /// the volatile tail. `roughDraft` alone can never stand in for it — it holds
  /// only the un-finalized fragment and is *cleared* the moment a segment
  /// finalizes, which is precisely when this grows.
  @Published private(set) var finalizedDraft = ""
  /// Concurrent polish calls in flight; `isPolishInProgress` is this > 0.
  private var polishInFlight = 0
  /// Terms auto-learn may still store this session. Streaming polishes once
  /// per sentence, so without a session budget one talkative minute could
  /// write a dozen permanent dictionary entries.
  private var autoLearnBudget = AutoLearn.maxCandidatesPerSession
  /// Bumped every time a streaming session's state is torn down.
  ///
  /// Refinement can outlive its session — a polish call may still be waiting on
  /// the network when the user releases the key and starts talking again — and
  /// every piece of state it writes (`polishInFlight`, the last-result
  /// diagnostics, `autoLearnBudget`) belongs to the controller, not the
  /// session. A stale epoch is how a dead session's polish is told it no longer
  /// speaks for the HUD.
  private var sessionEpoch: UInt64 = 0

  // MARK: - Review delivery session state (plan 07)

  /// A session's text sitting in the review panel, waiting on the owner.
  ///
  /// Held here rather than read back off the controller at Apply time: the
  /// session that produced this text is over by then, and every field the
  /// decision needs — its target pid, what it started from — belongs to that
  /// session and not to whatever came after it.
  private struct PendingReview {
    /// Identity of the REVIEW, not of the session that filled it. A
    /// continuation carries this forward: it extends the batch rather than
    /// replacing it, so a decision made after it must still land. Only a
    /// genuinely new card — one that replaced this one on screen — gets a new
    /// id, and that is what makes a decision from the old one ignorable.
    var id = UUID()
    /// How many sessions have added to this review. Extending bumps it;
    /// replacing does not exist for it, because a replacement is a new id.
    /// Distinguishes "extended" from "superseded" for anything that has to
    /// tell them apart after the fact.
    var generation: Int = 0
    /// The whole batch as the PIPELINE produced it — every session's polished
    /// text, appended. Not what is in the box: the owner's edits belong to the
    /// owner, and this is the `before` side of the diff Apply learns from.
    var polished: String
    /// The rules + dictionary result behind `polished`, accumulated the same
    /// way.
    var offline: String
    /// The target captured when the hotkey last went down. **Newest capture
    /// wins**: the owner may have moved to another app between the first
    /// session and the continuation, and the app they were dictating into when
    /// they last spoke is the one they mean.
    var target: FocusedTarget?
    var latency: TimeInterval
    /// One durable entry represents the open review batch, including any
    /// continuation that extends it.
    var historyID: UUID? = nil
  }

  private var pendingReview: PendingReview? {
    didSet { isReviewing = pendingReview != nil }
  }
  private let review: any DictationReviewPresenting

  /// True while a continuation session is recording into an open review card.
  ///
  /// Published because the HUD needs it: `isReviewing` alone suppresses the
  /// pill outright, which is right for a card sitting there waiting on the
  /// owner and wrong the moment the microphone is open again.
  @Published private(set) var isReviewRecording = false

  /// How long Apply waits after the card goes away before posting keystrokes,
  /// so the target app's own window has key status back. See `injectReviewed`.
  private static let reviewKeyRestoreSettleNs: UInt64 = 80_000_000

  init(
    permissions: PermissionsCoordinator? = nil,
    capture: MicCapture? = nil,
    hotkeyMonitor: HotkeyMonitor? = nil,
    review: (any DictationReviewPresenting)? = nil,
    historyStore: DictationHistoryStore? = nil
  ) {
    self.settings = DictationSettingsStore.load()
    self.historyStore = historyStore ?? DictationHistoryStore()
    self.dictationHistory = self.historyStore.entries
    self.permissions = permissions ?? PermissionsCoordinator()
    self.capture = capture ?? MicCapture()
    self.review = review ?? DictationReviewPresenter()
    self.hotkeyMonitor = hotkeyMonitor ?? HotkeyMonitor(
      triggerKey: self.settings.trigger,
      activationMode: self.settings.activation
    )

    self.permissions.onStatusChange = { [weak self] in
      self?.applyPermissionGate()
    }
    self.hotkeyMonitor.onTransition = { [weak self] transition in
      DispatchQueue.main.async { [weak self] in
        self?.handle(transition)
      }
    }
    launchObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishLaunchingNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.start()
      }
    }
    activationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refreshPermissions()
      }
    }

    // P2: route PCM buffers to the active speech stream
    self.capture.onPCMBuffer = { [weak self] buffer in
      guard let self, let stream = self.speechStream else { return }
      do {
        try stream.feed(buffer)
      } catch {
        self.logger.error("SpeechStream.feed failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    applyPermissionGate()
  }

  func start() {
    guard !hasStarted else {
      refreshPermissions()
      return
    }
    hasStarted = true
    refreshPermissions()
  }

  func refreshPermissions() {
    permissions.refresh()
    applyPermissionGate()
  }

  /// Reload settings from the store and re-apply (e.g. after the Settings UI saves).
  func reloadSettings() {
    settings = DictationSettingsStore.load()
    applySettings()
  }

  // MARK: - Private helpers

  private func applySettings() {
    hotkeyMonitor.triggerKey = settings.trigger
    hotkeyMonitor.activationMode = settings.activation

    // If the hotkey monitor is already running, restart it with the new config.
    if hotkeyMonitor.isRunning {
      hotkeyMonitor.stop()
      if state.isPermissionBlocked == false {
        hotkeyMonitor.start()
      }
    }
  }

  private func applyPermissionGate() {
    guard permissions.isReady else {
      if capture.isCapturing {
        cancelSession()
      }
      hotkeyMonitor.stop()
      state = .disabled(reason: permissions.blockingReason)
      return
    }

    if state.isPermissionBlocked {
      state = .idle
    }

    guard hasStarted, !hotkeyMonitor.isRunning else { return }
    guard hotkeyMonitor.start() else {
      let reason = hotkeyMonitor.unavailableReason
        ?? "The hotkey monitor is unavailable."
      state = .disabled(reason: reason)
      return
    }

    if state.isPermissionBlocked {
      state = .idle
    }
  }

  private func handle(_ transition: HotkeyTransition) {
    switch transition {
    case .began:
      holdBeganAt = Date()
      beginCaptureAndSpeech()
    case .ended:
      endCaptureAndFinalize()
    }
  }

  // MARK: - P2 session lifecycle

  private func beginCaptureAndSpeech() {
    guard permissions.isReady, hotkeyMonitor.isRunning else { return }
    guard !capture.isCapturing, !isSessionPending else { return }

    switch state {
    case .idle:
      break
    case .failed:
      state = .idle
    default:
      return
    }

    // In `.review` the card is the session's ONE surface for its whole life, so
    // it goes up here — before a word has been recognized — rather than at stop.
    // A press with a card already open extends that card instead (plan 14).
    beginOrOpenReviewCard()

    isSessionPending = true

    // What this session asks the recognizer for, and what it is allowed to do
    // with the results. Review and streaming share the live recognizer and
    // share nothing else: review accumulates and delivers exactly once, at the
    // end, into the panel.
    let plan = DictationSessionPlan.make(mode: settings.deliveryMode, engine: settings.engine)
    let usesScreenContext = settings.screenContextEnabled
    let usesScreenCaptureFallback = usesScreenContext && settings.screenCaptureFallbackEnabled

    // L1 context: frontmost app + focused window title, the custom dictionary,
    // and — for a streaming session — the target this session's text belongs
    // to. All of it is I/O: AX round-trips into a frontmost app that may not
    // answer, and a file read. So it is started here and awaited only where the
    // results are needed, at analyzer setup. Nothing on the main actor waits
    // for it: a wedged frontmost app must not freeze the HUD or hold the hotkey
    // handler, which is exactly what a synchronous `FocusedTarget.capture()`
    // here would do. An empty dictionary and an untrusted-for-AX process both
    // yield an empty hint list, which makes this a no-op.
    let contextLoad = Task.detached(priority: .userInitiated) {
      async let snapshot = ContextSnapshot.capture(includeFocusedText: usesScreenContext)
      let target = plan.capturesTarget ? await FocusedTarget.capture() : nil
      let terms = DictionaryStore.load()
      return (await snapshot, terms, target)
    }

    sessionContext = .empty
    sessionDictionary = []
    lastHypothesis = nil
    lastProcessedText = nil
    lastRulesResult = nil
    lastPolishResult = nil
    lastPolishWarning = nil
    polishInFlight = 0
    autoLearnBudget = AutoLearn.maxCandidatesPerSession
    resetStreamingSession()
    sessionUsesScreenContext = usesScreenContext
    sessionUsesScreenCaptureFallback = usesScreenCaptureFallback

    Task { [weak self] in
      let (snapshot, terms, startTarget) = await contextLoad.value
      guard let self, self.isSessionPending else { return }
      self.sessionContext = snapshot
      self.sessionDictionary = terms

      let hints = ContextHints.build(terms: terms, harvested: snapshot.harvestIdentifiers())

      // Create a speech stream matching the current engine choice
      let stream = makeDictationStream(
        for: self.settings.engine,
        contextualHints: hints,
        streaming: plan.wantsLiveDraft
      )
      self.speechStream = stream
      self.logger.info("Using engine: \(self.settings.engine.label)")
      self.logger.debug(
        "Session hints=\(hints.count) focusedText=\(snapshot.focusedText != nil)"
      )

      // The delivery queue must exist before the hypothesis loop starts, or a
      // segment arriving early would have nowhere to go.
      if let startTarget {
        self.sessionTarget = startTarget
      }
      if plan.deliversMidSession, let startTarget {
        if startTarget.isSecureInput {
          // Batch delivery refuses secure fields with a notice at the end;
          // streaming would have to refuse once per sentence instead.
          self.logger.notice("Streaming delivery skipped — focused field is secure")
        } else {
          self.deliveryQueue = self.makeDeliveryQueue(
            target: startTarget,
            terms: terms,
            snapshot: snapshot
          )
        }
      }

      // Observe partial hypotheses for diagnostics
      //
      // Stamped with the epoch of the session that started the stream.
      // `hypothesisTask.cancel()` does not unwind a value already handed to
      // `MainActor.run`, so a hypothesis can land after teardown — and with a
      // review card open, a finished session's words would then be drawn on the
      // card belonging to the next one.
      let epoch = self.sessionEpoch
      self.hypothesisTask = Task { [weak self] in
        guard let self else { return }
        for await hypothesis in stream.hypotheses {
          await MainActor.run {
            self.handleHypothesis(hypothesis, epoch: epoch)
          }
        }
      }

      // Start speech recognition first, then capture once ready
      do {
        try await stream.start()
      } catch {
        self.isSessionPending = false
        self.speechStream = nil
        self.resetStreamingSession()
        self.endReviewRecording()
        self.state = .failed(message: error.localizedDescription)
        self.logger.error("SpeechStream.start failed: \(error.localizedDescription, privacy: .public)")
        return
      }

      // Only now is it known what the engine that actually started can do — a
      // SpeechAnalyzer session that fell back to SFSpeechRecognizer reports
      // finality once, at the end, so it has neither a live draft nor segments.
      self.isLiveDraftSession = plan.wantsLiveDraft && stream.supportsLiveDraft
      Task {
        await DebugFileLog.shared().write(
          "session gate mode=\(plan.deliversMidSession ? "streaming" : "batch") "
            + "wantsDraft=\(plan.wantsLiveDraft) "
            + "supportsDraft=\(stream.supportsLiveDraft) "
            + "liveDraft=\(self.isLiveDraftSession)"
        )
      }
      self.isStreamingSession = self.deliveryQueue != nil && stream.deliversSegments
      if plan.deliversMidSession, !self.isStreamingSession {
        self.logger.info("Streaming delivery unavailable this session — using batch delivery")
        self.resetStreamingSession()
      }

      // Speech is ready — now start microphone capture
      guard self.isSessionPending else {
        stream.cancel()
        self.speechStream = nil
        self.resetStreamingSession()
        self.endReviewRecording()
        return
      }
      do {
        try self.capture.start()
        self.isSessionPending = false
        self.state = .listening
        let modeLabel = self.settings.activation == .hold ? "Hold" : "Toggle"
        self.logger.info("\(modeLabel) \(self.settings.trigger.kind == .fnGlobe ? "Fn/Globe" : "keyCode") started dictation session")
      } catch {
        stream.cancel()
        self.isSessionPending = false
        self.speechStream = nil
        self.resetStreamingSession()
        self.endReviewRecording()
        self.state = .failed(message: error.localizedDescription)
        self.logger.error("microphone capture failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func endCaptureAndFinalize() {
    // If we're still awaiting speech.start(), cancel and return
    if isSessionPending {
      isSessionPending = false
      speechStream?.cancel()
      speechStream = nil
      resetStreamingSession()
      endReviewRecording()
      state = .idle
      logger.info("Dictation session cancelled before speech started")
      return
    }

    guard capture.isCapturing else { return }
    capture.stop()
    lastCaptureDiagnostics = capture.diagnostics

    state = .finalizing
    // The draft was a preview of text that is now being finalized; the pill
    // moves to its processing state and must not keep offering it.
    roughDraft = ""

    if isStreamingSession {
      finalizeStreamingSession()
      return
    }

    Task {
      let finalText: String
      do {
        finalText = try await speechStream?.finish() ?? ""
      } catch is CancellationError {
        await MainActor.run {
          self.isSessionPending = false
          self.endReviewRecording()
          self.state = .idle
          self.speechStream = nil
        }
        return
      } catch {
        await MainActor.run {
          self.isSessionPending = false
          self.endReviewRecording()
          self.state = .failed(message: error.localizedDescription)
          self.speechStream = nil
          self.logger.error("SpeechStream.finish failed: \(error.localizedDescription, privacy: .public)")
        }
        return
      }

      await MainActor.run {
        self.isSessionPending = false
        // The recognizer is done, so nothing more may arrive claiming to be
        // this session's live draft. Only a live-draft session has a loop still
        // running here at all; cancelling an already-finished one is a no-op.
        self.hypothesisTask?.cancel()
        self.hypothesisTask = nil
        self.isLiveDraftSession = false
        self.roughDraft = ""

        let startTime = self.holdBeganAt ?? Date()
        let latency = Date().timeIntervalSince(startTime)
        self.lastLatency = latency
        self.lastHypothesis = finalText

        // --- Formatter pipeline (rules → dictionary replacements → polish) ---
        // L2 runs unconditionally: deterministic, offline, and the only
        // spelling fix available when polish is disabled or fails.
        let rulesResult = WordReplacements.apply(
          Formatter.applyRules(finalText),
          terms: self.sessionDictionary
        )
        self.lastRulesResult = rulesResult
        self.lastPolishResult = nil
        self.lastPolishWarning = nil

        if self.settings.polishEnabled, !rulesResult.isEmpty {
          let modelID = self.settings.polishModelID
            ?? ModelRegistry.defaultModel(for: .summary)

          self.logger.info("Polishing with model=\(modelID, privacy: .public)")
          self.isPolishInProgress = true

          let vocabulary = ContextHints.promptVocabulary(
            terms: self.sessionDictionary,
            harvested: self.sessionContext.harvestIdentifiers()
          )

          Task {
            let polished: String
            do {
              // The optional visual fallback is deliberately reached only on
              // this completion path. Streaming polish uses AX context from
              // session start and never captures a screenshot mid-dictation.
              let context = await self.cleanupContextForCurrentSession(
                allowScreenCapture: true
              )
              polished = try await PolishClient.polish(
                rulesResult,
                modelID: modelID,
                vocabulary: vocabulary,
                context: context
              )
              self.lastPolishResult = polished
              self.lastPolishWarning = nil
              self.logger.info("Polish succeeded")
            } catch {
              self.lastPolishResult = nil
              self.lastPolishWarning = "Polish failed: \(error.localizedDescription). Using rules-only result."
              let detail = (error as? PolishError)?.safeLogDescription ?? "unexpected error"
              self.logger.warning("Polish failed: \(detail, privacy: .public)")
              // Fall back to rules-only.
              self.deliver(rulesResult, offline: rulesResult, latency: latency)
              return
            }

            self.deliver(polished, offline: rulesResult, latency: latency)
            // After injection, never before: learning is bookkeeping and must
            // not delay the text reaching the user's cursor. Review mode is the
            // exception — its text is not the owner's yet, so `deliver` defers
            // every diff to the moment they apply it.
            if self.settings.deliveryMode != .review {
              self.learnTerms(before: rulesResult, after: polished)
            }
          }
        } else {
          self.deliver(rulesResult, offline: rulesResult, latency: latency)
        }
      }
    }
  }

  // MARK: - Hypothesis routing

  /// One hypothesis from the recognizer.
  ///
  /// With the live recognizer off this is exactly what it has always been:
  /// record the text for diagnostics. The live recognizer adds two arrivals — a
  /// finalized *segment* (a delta, accumulate it) and a volatile tail (replace
  /// the rough draft) — and never rewrites what an earlier segment produced.
  ///
  /// The delivery queue, not the arrival, decides whether a finalized segment
  /// goes anywhere. A review session has no queue: its segments accumulate and
  /// nothing is injected until the owner applies the panel's text, which is the
  /// whole difference between the two live modes.
  ///
  /// Internal for the same reason `deliver` is: this is the recognizer contract
  /// in full, and a stub `Hypothesis` drives it without a microphone.
  func handleHypothesis(_ hypothesis: Hypothesis) {
    if hypothesis.isSegment {
      finalizedDraft = StreamingDelivery.joined(finalizedDraft, hypothesis.text)
      lastHypothesis = finalizedDraft
      logger.debug("Segment finalized: \"\(hypothesis.text, privacy: .public)\"")
      // The volatile tail this finalized: the HUD must stop offering it as a
      // rough draft of text that is already recognized. No further volatile
      // result is guaranteed to arrive and clear it.
      roughDraft = ""
      publishReviewDraft()
      guard let deliveryQueue else { return }
      for segment in segmenter.append(hypothesis.text) {
        deliveryQueue.enqueue(segment)
      }
      return
    }

    if isLiveDraftSession {
      if hypothesis.isFinal {
        // A turn finalizes: fold it into the session draft as its own line
        // so the growing pill keeps everything the user has said, then clear
        // the volatile tail it finalized.
        let line = hypothesis.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty {
          finalizedDraft = finalizedDraft.isEmpty ? line : finalizedDraft + "\n" + line
        }
        roughDraft = ""
      } else {
        roughDraft = hypothesis.text
      }
      publishReviewDraft()
      Task { await DebugFileLog.shared().write(
        "draft update final=\(hypothesis.isFinal) chars=\(hypothesis.text.count) text=\"\(hypothesis.text)\""
      ) }
      return
    }

    lastHypothesis = hypothesis.text
    logger.debug("Hypothesis isFinal=\(hypothesis.isFinal) text=\"\(hypothesis.text, privacy: .public)\"")
  }

  /// A hypothesis on behalf of the session that was live at `epoch`.
  ///
  /// "A finished session stops talking", applied at the one boundary where the
  /// recognizer's own feed crosses into controller state: a stale hypothesis is
  /// dropped rather than repopulating a draft its session's teardown already
  /// cleared — and, with a review card open, rather than drawing a dead
  /// session's words on the card the next one is filling.
  ///
  /// Internal so a test can hand the controller a hypothesis stamped with an
  /// epoch that has since been bumped, which no amount of driving the live path
  /// makes reproducible.
  func handleHypothesis(_ hypothesis: Hypothesis, epoch: UInt64) {
    guard epoch == sessionEpoch else {
      logger.debug("Dropped a hypothesis from a finished session (epoch \(epoch))")
      return
    }
    handleHypothesis(hypothesis)
  }

  /// Mirror the live draft into an open review card.
  ///
  /// Only while a continuation is recording into one: `isReviewRecording` is
  /// set by `beginReviewContinuationIfOpen` and cleared by
  /// `endReviewContinuation`, so a first review session (no card yet) and every
  /// non-review session publish nothing. Display only — the card's editor is
  /// untouched, and the continuation's finished text still reaches the owner's
  /// buffer once, at stop, through `DictationReview.appended`.
  private func publishReviewDraft() {
    guard isReviewRecording else { return }
    review.setDraft(HUDDraft(finalized: finalizedDraft, volatileTail: roughDraft))
  }

  /// Mirror a session failure onto whichever surface exists.
  ///
  /// In `.review` the card is the session's ONE surface from the hotkey press to
  /// the decision, and `HUDState.compute` hides the pill outright while
  /// `isReviewing` — so a `.failed` that only reached the pill would be a
  /// session failing in silence. Driven from `state`'s `didSet` rather than from
  /// the half-dozen sites that assign `.failed`: one place to be right, and no
  /// way for a new failure path to forget.
  ///
  /// A no-op when no card is up, which is the whole split — `isReviewing` is
  /// exactly "a card exists", so the two rules can never both fire or both miss.
  private func publishReviewError() {
    guard pendingReview != nil else { return }
    if case .failed(let message) = state {
      review.setError(message)
    } else {
      review.setError(nil)
    }
  }

  // MARK: - Streaming delivery

  /// Build the model context for this session. Screen content is never stored
  /// in history or diagnostics; this value exists only until the request is
  /// assembled and the task completes.
  private func cleanupContextForCurrentSession(
    allowScreenCapture: Bool
  ) async -> ContextSnapshot? {
    guard sessionUsesScreenContext else { return nil }

    var context = sessionContext
    if allowScreenCapture,
       sessionUsesScreenCaptureFallback,
       ScreenContextCapture.shouldUseVisualFallback(focusedText: context.focusedText),
       let ocrText = await ScreenContextCapture.captureVisibleText(
         processID: context.processID,
         windowTitle: context.windowTitle
       )
    {
      context.focusedText = ocrText
    }
    return context.cleanupContext(enabled: true)
  }

  /// Build this session's delivery queue: the same L1 → L2 → L3 pipeline the
  /// batch path runs, applied per sentence, with delivery serialized.
  private func makeDeliveryQueue(
    target: FocusedTarget,
    terms: [DictionaryTerm],
    snapshot: ContextSnapshot
  ) -> StreamingDeliveryQueue {
    let polishEnabled = settings.polishEnabled
    let modelID = settings.polishModelID ?? ModelRegistry.defaultModel(for: .summary)
    let vocabulary = ContextHints.promptVocabulary(
      terms: terms,
      harvested: snapshot.harvestIdentifiers()
    )
    // Streaming requests happen before dictation completion, so they may use
    // the bounded AX sample captured at session start but never the visual
    // screenshot fallback.
    let context = snapshot.cleanupContext(enabled: sessionUsesScreenContext)

    let runPolish: @Sendable (String) async throws -> String = { text in
      try await PolishClient.polish(
        text,
        modelID: modelID,
        vocabulary: vocabulary,
        context: context
      )
    }
    let polish: (@Sendable (String) async throws -> String)? = polishEnabled ? runPolish : nil

    // Bound to the session that built this queue: a refinement that returns
    // after teardown must not touch the next session's polish state.
    let epoch = sessionEpoch

    let refine: StreamingDeliveryQueue.Refine = { [weak self] segment in
      // A fragment never reaches polish, so it never counts as polish in
      // flight either.
      let willPolish = polish != nil && segment.isWholeSentence
      if willPolish { await self?.beginPolish(epoch: epoch) }
      let refined = await StreamingDelivery.refine(segment, terms: terms, polish: polish)
      if willPolish { await self?.endPolish(refined, epoch: epoch) }
      return refined.text
    }

    let deliver: StreamingDeliveryQueue.Deliver = { [weak self] delta in
      guard let self else { return }
      let historyID = self.prepareStreamingHistory(delta, target: target)
      let result = await self.injector.inject(delta, target: target, mode: .append)
      if let historyID {
        self.updateHistoryDelivery(historyID, result: result)
      }
    }

    return StreamingDeliveryQueue(refine: refine, deliver: deliver)
  }

  private func beginPolish(epoch: UInt64) {
    guard epoch == sessionEpoch else { return }
    polishInFlight += 1
    isPolishInProgress = true
  }

  private func endPolish(_ refined: StreamingDelivery.RefinedSentence, epoch: UInt64) {
    guard epoch == sessionEpoch else {
      logger.debug("Ignoring polish result from a finished session")
      return
    }
    polishInFlight = max(0, polishInFlight - 1)
    isPolishInProgress = polishInFlight > 0
    guard !refined.offline.isEmpty else { return }

    lastRulesResult = refined.offline
    if let error = refined.polishError {
      lastPolishResult = nil
      lastPolishWarning = "Polish failed: \(error.localizedDescription). Using rules-only result."
      let detail = (error as? PolishError)?.safeLogDescription ?? "unexpected error"
      logger.warning("Polish failed: \(detail, privacy: .public)")
      return
    }
    lastPolishResult = refined.text
    learnTerms(before: refined.offline, after: refined.text)
  }

  /// Stop path for a streaming session.
  ///
  /// Order matters: drain the recognizer, then make sure every segment it
  /// emitted has reached the queue, and only then flush the un-finalized tail
  /// — enqueued last so it is delivered last. Everything already typed into
  /// the target stands regardless of what happens here.
  private func finalizeStreamingSession() {
    let stream = speechStream
    let queue = deliveryQueue
    let epoch = sessionEpoch

    Task {
      var finishError: (any Error)?
      do {
        let recognized = try await stream?.finish() ?? ""
        if !recognized.isEmpty {
          self.lastHypothesis = recognized
        }
      } catch is CancellationError {
        // Nothing to report: whatever was delivered stands.
      } catch {
        finishError = error
        self.logger.error(
          "SpeechStream.finish failed: \(error.localizedDescription, privacy: .public)"
        )
      }

      await self.drainHypotheses(timeout: 2.0)
      self.roughDraft = ""

      if let queue {
        if let tail = self.segmenter.flush() {
          queue.enqueue(tail)
        }
        if queue.enqueuedCount > 0 {
          self.state = .injecting
        }
        await queue.finish()
        self.lastProcessedText = queue.deliveredText
      }

      self.finishStreamingSession(error: finishError, epoch: epoch)
    }
  }

  /// Wait for the hypothesis loop to end, but never longer than `timeout`.
  ///
  /// The recognizer's results stream normally ends inside `finish()`, which
  /// ends the hypothesis stream with it. When the analyzer stalls and the
  /// stream's own watchdog returns instead, nothing ever ends it — so the loop
  /// is cancelled rather than waited on forever.
  ///
  /// Cancelling the loop does not drop what it has already buffered, and it
  /// does not have to: `withTaskGroup` cannot return until every child has
  /// finished, and the child awaiting `task.value` finishes only when the loop
  /// itself does. So by the time this returns, every segment the recognizer
  /// emitted has reached the queue — which is what lets the tail be flushed
  /// afterwards and still be delivered last.
  private func drainHypotheses(timeout: TimeInterval) async {
    guard let task = hypothesisTask else { return }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { _ = await task.value }
      group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
      _ = await group.next()
      task.cancel()
      group.cancelAll()
    }
    hypothesisTask = nil
  }

  /// Land a streaming session: report it, then drop its state.
  ///
  /// Runs after several awaits, and the session it belongs to may be gone by
  /// then — a permission loss tears one down mid-finalize. A stale finish must
  /// not report its result over whatever replaced it, least of all by putting
  /// the controller back to `.idle` after it was disabled.
  private func finishStreamingSession(error: (any Error)?, epoch: UInt64) {
    guard epoch == sessionEpoch else {
      logger.debug("Skipping teardown for a session that was already torn down")
      return
    }
    isSessionPending = false
    polishInFlight = 0
    isPolishInProgress = false

    let latency = Date().timeIntervalSince(holdBeganAt ?? Date())
    lastLatency = latency
    let delivered = deliveryQueue?.deliveredText ?? ""
    logger.info(
      "Streaming session: latency=\(String(format: "%.2f", latency))s text=\"\(delivered, privacy: .public)\""
    )

    if let error, delivered.isEmpty {
      // Nothing reached the target, so the failure is the whole story.
      state = .failed(message: error.localizedDescription)
    } else if let notice = injector.lastSecureFieldNotice {
      state = .failed(message: notice)
      Task {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        self.injector.clearSecureFieldNotice()
        self.state = .idle
      }
    } else if let historyID = streamingHistoryID,
              let entry = historyStore.entry(id: historyID),
              entry.status == .failed {
      state = .failed(message: entry.statusDetail ?? "Nota could not insert the dictation")
    } else {
      state = .idle
    }

    speechStream = nil
    resetStreamingSession()
  }

  /// Drop every trace of a streaming session, including work still in flight.
  ///
  /// The epoch bump and the queue cancellation are the same guarantee stated
  /// twice: nothing this session started may write to the controller once the
  /// session is gone. Cancelling a queue that already finished is a no-op, so
  /// this is safe on the normal stop path as well as on teardown.
  private func resetStreamingSession() {
    sessionEpoch &+= 1
    deliveryQueue?.cancel()
    hypothesisTask?.cancel()
    hypothesisTask = nil
    deliveryQueue = nil
    streamingHistoryID = nil
    sessionTarget = nil
    sessionContext = .empty
    sessionUsesScreenContext = false
    sessionUsesScreenCaptureFallback = false
    isStreamingSession = false
    isLiveDraftSession = false
    segmenter = SentenceSegmenter()
    finalizedDraft = ""
    roughDraft = ""
  }

  // MARK: - Review delivery (plan 07)

  /// Hand this session's finished text to whichever delivery mode is on.
  ///
  /// `.immediate` and `.streaming` inject it; `.review` shows it to the owner
  /// first and injects nothing until they say so.
  ///
  /// Internal rather than private: this is where the review branch begins, and
  /// with a stub `DictationReviewPresenting` injected it is the only way to
  /// exercise apply, discard, and a superseded review without a window server.
  func deliver(_ text: String, offline: String, latency: TimeInterval) {
    guard settings.deliveryMode == .review else {
      // The card's listening state is cleared by `presentReview`, and this
      // branch never reaches it. The Delivery picker can change *mid-session*
      // (`reloadSettings`), so a continuation legitimately started against an
      // open card can arrive here — and leaving `isReviewRecording` set would
      // wedge that card for the rest of the run: `finishReview` refuses every
      // decision while it is true, so neither ⌘↩ nor Escape would ever land.
      // Idempotent, and a no-op for every session that was not a continuation.
      endReviewRecording()
      doInject(text, latency: latency)
      sessionContext = .empty
      sessionUsesScreenContext = false
      sessionUsesScreenCaptureFallback = false
      return
    }
    presentReview(polished: text, offline: offline, latency: latency)
    sessionContext = .empty
    sessionUsesScreenContext = false
    sessionUsesScreenCaptureFallback = false
  }

  /// A trigger press while a review card is open starts a CONTINUATION of that
  /// review rather than a new, independent session (plan 14, user feedback
  /// 2026-07-28).
  ///
  /// Before this, the press discarded the card and the text in it was gone —
  /// which made the mode punishing to use exactly when it was working, because
  /// "one more sentence" cost everything already reviewed. Now the card stays,
  /// shows that it is listening, and refuses Apply/Discard until this session's
  /// text has landed in it.
  ///
  /// Only the mode that knows how to *fill* a card may extend one. The Delivery
  /// picker can be changed while a card sits on screen — the panel is
  /// nonactivating, so Settings opens over it perfectly happily, and
  /// `reloadSettings` takes effect immediately — and nothing in `.immediate` or
  /// `.streaming` ever reaches `presentReview`. A continuation started in one of
  /// those modes would therefore never be *ended* on the success path, leaving
  /// `isReviewRecording` true, every decision refused by `finishReview`, and the
  /// card undecidable for the rest of the run. So a press in any other mode does
  /// what plan 07 always did: cancels the open review, inserting nothing, and
  /// this session's text goes to the target app as that mode promises.
  ///
  /// Returns whether a continuation was started. Internal rather than private:
  /// `beginCaptureAndSpeech` needs a microphone, an analyzer and three
  /// permission grants, and the claim under test — a press extends rather than
  /// discards — needs none of them.
  /// What a trigger press does to the review card, whichever state it is in.
  ///
  /// One entry point for the two cases, because from the owner's side they are
  /// the same gesture: a card open → this session extends it; no card → this
  /// session opens one, empty and recording. Before 2026-08-03 the second case
  /// did not exist and the first session's live feedback went to the HUD
  /// instead, which is the two-surface lifecycle the owner asked to collapse
  /// ("one pill only").
  ///
  /// Returns whether a card is now recording.
  @discardableResult
  func beginOrOpenReviewCard() -> Bool {
    if pendingReview != nil { return beginReviewContinuationIfOpen() }
    guard settings.deliveryMode == .review else { return false }
    return openRecordingReviewCard()
  }

  /// Put an empty card on screen for a session that has just started.
  ///
  /// It goes up through exactly the same `openReview` every other card does, so
  /// there is one presenter call, one `pendingReview`, one set of decision
  /// callbacks and one failure path. What makes it the *recording* state is the
  /// same flag a continuation sets: the card is one component with two states,
  /// not two components.
  ///
  /// Nothing is recorded to history yet — an empty entry is not a dictation.
  /// `extendReview` creates it the moment the batch first has text.
  @discardableResult
  private func openRecordingReviewCard() -> Bool {
    openReview(
      PendingReview(polished: "", offline: "", target: nil, latency: 0),
      text: ""
    )
    // `openReview` clears `pendingReview` when the card could not be shown, and
    // has already reported it. Nothing is left listening to a card that is not
    // there; the session runs on and `presentReview` will try again at stop.
    guard pendingReview != nil else { return false }
    isReviewRecording = true
    review.setListening(true)
    review.setDraft(.empty)
    logger.info("Review card opened for a new session")
    return true
  }

  @discardableResult
  func beginReviewContinuationIfOpen() -> Bool {
    guard pendingReview != nil else { return false }
    guard settings.deliveryMode == .review else {
      cancelOpenReview(reason: "delivery mode is no longer Review")
      return false
    }
    pendingReview?.generation += 1
    isReviewRecording = true
    review.setListening(true)
    // The card grows for the block here, once, and it opens empty: the previous
    // continuation's words belong to the buffer now, not to this one.
    review.setDraft(.empty)
    logger.info("Review continuation started (generation \(self.pendingReview?.generation ?? 0))")
    return true
  }

  /// Take an open card down without a decision: nothing is inserted and nothing
  /// is learned.
  ///
  /// `pendingReview` is cleared *before* the panel is dismissed, so the
  /// presenter's own "one decision per review" route — `dismiss()` delivers the
  /// pending request's discard — finds no review to attribute it to and stops
  /// at the `id` guard in `finishReview`.
  private func cancelOpenReview(reason: String) {
    guard pendingReview != nil else { return }
    endReviewContinuation()
    pendingReview = nil
    review.dismiss()
    logger.notice(
      "Open review cancelled — \(reason, privacy: .public); nothing was inserted"
    )
  }

  /// Stop showing the card as listening. Idempotent, and safe on a session that
  /// was never a continuation.
  private func endReviewContinuation() {
    guard isReviewRecording else { return }
    isReviewRecording = false
    review.setListening(false)
    // The draft was a witness to an open microphone. The microphone is shut,
    // and what it heard is about to be appended to the buffer — leaving the
    // block up would show the same words twice.
    review.setDraft(.empty)
  }

  /// Stop recording AND take an empty card down.
  ///
  /// The abort paths' version. Since the card now opens at session *start*, a
  /// session that never produced anything — a press-and-release, a recognizer
  /// that failed to start, a microphone that would not open — can leave a card
  /// on screen holding nothing. It is not a decision anyone can make: Apply is
  /// disabled on empty text, and the only thing Escape would throw away is
  /// nothing.
  ///
  /// A card holding a real batch is never touched. The test is the pipeline's
  /// own accumulation AND the editor, because the owner may have typed into a
  /// card whose session heard nothing, and that text is theirs.
  private func endReviewRecording() {
    endReviewContinuation()
    guard let open = pendingReview else { return }
    guard open.polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          (review.editorText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    cancelOpenReview(reason: "the session that opened the card produced nothing")
  }

  /// Open the review panel on this session's text — or, when a card is already
  /// open, add this session's text to it.
  private func presentReview(polished: String, offline: String, latency: TimeInterval) {
    isPolishInProgress = false
    speechStream = nil
    lastLatency = latency
    // Nothing has reached the target app, so nothing may read as inserted —
    // the HUD's success snippet comes from this field, and the last session's
    // text is still in it.
    lastProcessedText = nil
    endReviewContinuation()

    guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // Nothing was recognized. An empty panel is worse than no panel — so a
      // card this session opened and never filled goes away, while a
      // continuation that heard nothing leaves the card exactly as it was.
      // `endReviewRecording` is the whole distinction, in one place.
      endReviewRecording()
      state = .idle
      return
    }

    if let open = pendingReview {
      if extendReview(open, polished: polished, offline: offline, latency: latency) {
        state = .idle
        return
      }

      // The card is no longer there to write into, so this is a genuine
      // REPLACEMENT — new id, which is what makes a late decision from the old
      // card ignorable. The batch is not lost: the fresh card carries
      // everything the pipeline accumulated plus this session's text. What
      // cannot be carried is the owner's editing — the editor is exactly what
      // could not be read — so the pipeline's own accumulation is the best
      // available account of the batch, and `generation` comes forward because
      // the same number of sessions built it.
      let carried = DictationReview.appended(buffer: open.polished, addition: polished)
      openReview(
        PendingReview(
          generation: open.generation,
          polished: carried,
          offline: DictationReview.appended(buffer: open.offline, addition: offline),
          target: reviewTarget(sessionTarget) ?? open.target,
          latency: latency,
          historyID: open.historyID
        ),
        text: carried
      )
      logger.notice("Review card could not be extended — reopened carrying the batch")
      return
    }

    openReview(
      PendingReview(
        polished: polished,
        offline: offline,
        target: reviewTarget(sessionTarget),
        latency: latency
      ),
      text: polished
    )
  }

  /// A capture this mode is allowed to insert through, or nil.
  ///
  /// `injectReviewed` requires a pid, and requires it not to be Nota's own —
  /// injecting "wherever" is the failure review mode exists to prevent. That
  /// check runs at Apply, by which point `finishReview` has already taken the
  /// card down, so a target that fails it destroys the whole accumulated batch.
  /// Applying the same rule when the target is *recorded* turns that into a
  /// refusal to overwrite: a capture Apply could never use loses to the one
  /// that already worked.
  ///
  /// Nota's own pid is not hypothetical. The card is nonactivating, so the
  /// target app stays frontmost — but the owner can bring Nota forward between
  /// two sentences (menu-bar icon, Cmd-, for the Dictionary tab) and press the
  /// trigger from there, and `FocusedTarget.capture()` then records Nota.
  private func reviewTarget(_ candidate: FocusedTarget?) -> FocusedTarget? {
    guard let candidate, let pid = candidate.processID else { return nil }
    guard pid != ProcessInfo.processInfo.processIdentifier else {
      logger.notice("Ignoring a review capture that landed on Nota itself")
      return nil
    }
    return candidate
  }

  /// Add a continuation's finished text to the open card.
  ///
  /// Appends to what is in the EDITOR, not to what the pipeline produced: by
  /// now the owner may have corrected half the card, and those edits are
  /// theirs. Returns false when the card is not there to write to, which sends
  /// the caller down the open-a-fresh-one path rather than losing the batch.
  private func extendReview(
    _ open: PendingReview,
    polished: String,
    offline: String,
    latency: TimeInterval
  ) -> Bool {
    guard let buffer = review.editorText else { return false }
    let combined = DictationReview.appended(buffer: buffer, addition: polished)
    guard review.replaceEditorText(combined) else { return false }

    var extended = open
    // Same id: this review was EXTENDED, not replaced, so the decision
    // callbacks the card is already holding stay valid.
    extended.polished = DictationReview.appended(buffer: open.polished, addition: polished)
    extended.offline = DictationReview.appended(buffer: open.offline, addition: offline)
    // Newest *usable* capture wins. A capture that failed — or that landed on
    // Nota itself, which a press made while Settings is frontmost does — keeps
    // the one that worked: both are targets `injectReviewed` refuses, and it
    // refuses them after the card is already down, so overwriting a good pid
    // with one of them would destroy the batch at Apply. The earlier session
    // already found somewhere valid.
    extended.target = reviewTarget(sessionTarget) ?? open.target
    extended.latency = latency
    if let historyID = extended.historyID {
      historyStore.update(id: historyID, text: combined, status: .pending, statusDetail: "Awaiting review")
      syncDictationHistory()
    } else {
      // The card was opened empty, at session start, so `openReview` recorded
      // nothing — a history entry with no text is not a dictation. This is the
      // moment the batch first has some, which is where the entry the whole
      // batch will be tracked under belongs.
      extended.historyID = recordHistory(text: combined, target: extended.target)
    }
    pendingReview = extended
    logger.info(
      "Review extended to \(combined.count) characters (generation \(extended.generation))"
    )
    return true
  }

  /// Put a fresh card on screen for `pending`, replacing anything already up.
  private func openReview(_ pending: PendingReview, text: String) {
    var pending = pending
    if pending.historyID == nil {
      // Only once there is something to record. A card opened at session start
      // carries no text yet; `extendReview` creates the entry when the batch
      // first has some, so history never holds an empty dictation.
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        pending.historyID = recordHistory(text: text, target: pending.target)
      }
    } else if let historyID = pending.historyID {
      historyStore.update(
        id: historyID,
        text: text,
        status: .pending,
        statusDetail: "Awaiting review",
        targetBundleID: pending.target?.bundleID,
        targetProcessID: pending.target?.processID.map { Int32($0) }
      )
      syncDictationHistory()
    }
    pendingReview = pending
    state = .idle

    let id = pending.id
    let shown = review.present(
      DictationReviewRequest(
        text: text,
        onApply: { [weak self] edited in
          self?.finishReview(.apply(edited), id: id)
        },
        onDiscard: { [weak self] in
          self?.finishReview(.discard, id: id)
        }
      )
    )
    guard shown else {
      // The card is a review session's only output, and `isReviewing`
      // suppresses the pill while one is open — a panel that never reached the
      // screen would leave the owner with no card, no pill and no error, and
      // the next hotkey press would throw this text away silently. Nothing is
      // inserted, which is the mode's promise; the failure is said out loud,
      // and clearing `pendingReview` lets the pill say it.
      pendingReview = nil
      if let historyID = pending.historyID {
        updateHistoryDelivery(
          historyID,
          status: .failed,
          detail: "Nota could not show the review card"
        )
      }
      logger.error("Review panel could not be shown — the session's text was not inserted")
      state = .failed(message: "Nota could not show the review card. Restart Nota to fix it.")
      return
    }
    logger.info("Review panel opened with \(text.count) characters")
  }

  /// Land a review decision.
  ///
  /// `id` is the same guard the streaming epoch is: the panel outlives the
  /// session that filled it, and a decision that arrives after the card was
  /// REPLACED must not be attributed to whatever replaced it. A continuation is
  /// not a replacement — it keeps the id and bumps `generation` — so the
  /// callbacks the open card is already holding stay valid across one, which is
  /// the whole point: ⌘↩ applies the batch, however many sessions built it.
  private func finishReview(_ decision: DictationReview.Decision, id: UUID) {
    guard let pending = pendingReview, pending.id == id else { return }
    // A decision may not land while more of this batch is still being spoken.
    // The card refuses both routes itself; this is the backstop for anything
    // that reaches the controller anyway.
    guard !isReviewRecording else {
      logger.notice("Review decision ignored — a continuation is still recording")
      return
    }
    pendingReview = nil
    review.dismiss()

    let resolution = DictationReview.resolve(
      polished: pending.polished,
      offline: pending.offline,
      decision: decision
    )

    guard let text = resolution.injection else {
      // The whole point of the mode: a discarded session inserts nothing and
      // teaches nothing. Nothing to hand back either — the panel never
      // activated Nota, so the app being dictated into was in front the whole
      // time and still is.
      if let historyID = pending.historyID {
        updateHistoryDelivery(historyID, status: .discarded, detail: "Discarded from review")
      }
      logger.info("Review discarded — nothing inserted")
      state = .idle
      return
    }

    if let historyID = pending.historyID {
      updateHistoryDelivery(historyID, status: .pending, detail: "Waiting for insertion")
    }
    injectReviewed(
      text,
      target: pending.target,
      latency: pending.latency,
      historyID: pending.historyID
    )
    // After injection, and only for text the owner actually applied.
    for pair in resolution.learn {
      learnTerms(before: pair.before, after: pair.after)
    }
  }

  /// Inject reviewed text into the target captured at SESSION START.
  ///
  /// Not `FocusedTarget.capture()` as the immediate path does: the panel holds
  /// key focus, so a fresh capture at Apply time would read Nota's own card as
  /// the focused element. The pid recorded when the hotkey went down is the one
  /// thing still pointing at the app being dictated into — and because the
  /// panel never activated Nota, that app is also still frontmost, so the
  /// events land without anything having to be brought back.
  private func injectReviewed(
    _ text: String,
    target: FocusedTarget?,
    latency: TimeInterval,
    historyID: UUID?
  ) {
    // A pid is required, and it may not be Nota's own. Injecting "wherever" is
    // exactly the failure this mode exists to prevent, so it refuses instead —
    // the text stays on the owner's screen in the panel they applied from.
    guard let target,
          let pid = target.processID,
          pid != ProcessInfo.processInfo.processIdentifier
    else {
      logger.error("Reviewed text has no usable target — refusing to insert it anywhere")
      if let historyID {
        updateHistoryDelivery(
          historyID,
          status: .failed,
          detail: "Nota lost track of the app you were dictating into"
        )
      }
      state = .failed(message: "Nota lost track of the app you were dictating into.")
      return
    }

    lastProcessedText = text
    state = .injecting
    logger.info(
      "Review applied: latency=\(String(format: "%.2f", latency))s text=\"\(text, privacy: .public)\""
    )

    Task {
      // FIRST, and this is the ⌘↩ bug (2026-07-28): wait for the owner's own
      // modifier keys to come up.
      //
      // The two ways out of the card run identical code — the key monitor and
      // the Apply button both end in `model.apply()` → `finish(.apply(…))` →
      // here — so the difference was never in Nota. On the shortcut route the
      // owner's ⌘ is *physically down* when this runs, and a `CGEvent` built
      // from `.combinedSessionState` inherits the real keyboard's modifiers. A
      // ⌘-tagged key-down is a shortcut, not text: the target routed it to
      // key-equivalent dispatch and dropped the payload, silently, while
      // `lastProcessedText` claimed success. `TextInjector` now zeroes the
      // flags on the events it builds; this covers the other half, which is
      // the target app's own modifier state arriving from the real keyboard.
      // Bounded — at the cap the text goes anyway, because a stuck modifier
      // may delay a session's output and never swallow it.
      let clearance = await ModifierClearance.wait()
      if clearance != .alreadyClear {
        self.logger.debug("Modifier clearance before review injection: \(String(describing: clearance), privacy: .public)")
      }

      // The card that just ordered out was the KEY window. Restore the
      // originally captured app and wait until WindowServer confirms it is
      // frontmost before sending a pid-targeted event. Without this, the
      // EventServer post can succeed while Electron/webview editors still have
      // no key window and silently drop the text.
      let focus = await target.restoreAndWait()
      guard focus.isReady else {
        self.logger.error(
          "Could not restore review target before injection: \(String(describing: focus), privacy: .public)"
        )
        let reason = InjectionFailure.noUsableTarget.description
        if let historyID {
          self.updateHistoryDelivery(historyID, status: .failed, detail: reason)
        }
        self.state = .failed(message: reason)
        return
      }

      // The target's window may regain key status a beat after it becomes
      // frontmost. Keep the bounded settle for that hand-off.
      try? await Task.sleep(nanoseconds: Self.reviewKeyRestoreSettleNs)
      let result = await self.injector.inject(text, target: target)
      if let historyID {
        self.updateHistoryDelivery(historyID, result: result)
      }
      if case .refused(let reason) = result {
        self.state = .failed(message: reason)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        self.injector.clearSecureFieldNotice()
        self.state = .idle
      } else if case .failed(_, let reason) = result {
        self.state = .failed(message: reason)
      } else {
        self.state = .idle
      }
    }
  }

  /// Record identifiers a diff corrected, so the next session gets them at
  /// L1/L2 without a paid call.
  ///
  /// Two kinds of caller, one gate. Polish supplies `before` = the offline text
  /// and `after` = its own output; the review panel supplies `before` = the
  /// polished text and `after` = what the owner typed over it, which is why the
  /// spoken form stored alongside the term is the exact wrong spelling that was
  /// on screen. Neither is allowed past `AutoLearn`'s identifier-shaped filter
  /// — a human edit is a reason to trust the correction, not a reason to let
  /// prose into the dictionary.
  ///
  /// Runs off the main actor: `DictionaryStore` writes atomically, so a
  /// background write racing a foreground read can only ever produce the old or
  /// the new file, never a half-written one. A write failure is logged and
  /// dropped — learning is an optimization, never a reason to surface an error
  /// after the text has already been injected.
  private func learnTerms(before: String, after: String) {
    guard autoLearnBudget > 0 else { return }
    // `AutoLearn.candidates` already caps one call at the session maximum; the
    // budget makes that a *session* cap when streaming polishes per sentence.
    let candidates = Array(
      AutoLearn.candidates(before: before, after: after).prefix(autoLearnBudget)
    )
    guard !candidates.isEmpty else { return }
    autoLearnBudget -= candidates.count
    let logger = self.logger
    Task.detached(priority: .utility) {
      for candidate in candidates {
        do {
          try DictionaryStore.add(
            candidate.term,
            spokenForms: [candidate.spokenForm],
            source: .learned
          )
          logger.info(
            "Learned \"\(candidate.term, privacy: .public)\" from \"\(candidate.spokenForm, privacy: .public)\""
          )
        } catch {
          logger.warning("Could not learn \(candidate.term, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
      }
    }
  }

  // MARK: - Dictation history

  private func syncDictationHistory() {
    dictationHistory = historyStore.entries
  }

  @discardableResult
  private func recordHistory(text: String, target: FocusedTarget?) -> UUID? {
    let id = historyStore.record(
      text: text,
      targetBundleID: target?.bundleID,
      targetProcessID: target?.processID.map { Int32($0) }
    )
    syncDictationHistory()
    return id
  }

  private func updateHistoryDelivery(
    _ id: UUID,
    status: DictationDeliveryStatus,
    detail: String?
  ) {
    historyStore.update(id: id, status: status, statusDetail: detail)
    syncDictationHistory()
  }

  private func updateHistoryDelivery(_ id: UUID, result: InjectionResult) {
    let status: DictationDeliveryStatus
    let detail: String?
    switch result {
    case .delivered(let strategy):
      status = .delivered
      detail = "Inserted via \(strategy.description)"
    case .attempted(let strategy):
      status = .attempted
      detail = "\(strategy.description) was sent; the target did not confirm insertion"
    case .refused(let reason):
      status = .failed
      detail = reason
    case .failed(let strategy, let reason):
      status = .failed
      detail = strategy.map { "\($0.description): \(reason)" } ?? reason
    }
    updateHistoryDelivery(id, status: status, detail: detail)
  }

  /// Streaming writes one durable entry before its first sentence is sent and
  /// grows that entry before each later sentence. This keeps partial text
  /// recoverable during a long session while still presenting one row per
  /// completed dictation.
  private func prepareStreamingHistory(_ delta: String, target: FocusedTarget) -> UUID? {
    if let id = streamingHistoryID, let existing = historyStore.entry(id: id) {
      let combined = existing.text + delta
      if existing.status != .failed {
        historyStore.update(
          id: id,
          text: combined,
          status: .pending,
          statusDetail: "Awaiting insertion",
          targetBundleID: target.bundleID,
          targetProcessID: target.processID.map { Int32($0) }
        )
      } else {
        historyStore.update(
          id: id,
          text: combined,
          statusDetail: existing.statusDetail
        )
      }
      syncDictationHistory()
      return id
    }

    streamingHistoryID = recordHistory(text: delta, target: target)
    return streamingHistoryID
  }

  /// Shared injection step after formatting/polish is resolved.
  private func doInject(_ text: String, latency: TimeInterval) {
    lastProcessedText = text
    isPolishInProgress = false
    self.logger.info(
      "Dictation session: latency=\(String(format: "%.2f", latency))s text=\"\(text, privacy: .public)\""
    )

    if !text.isEmpty {
      self.state = .injecting

      Task {
        // Awaited rather than called inline: reading the focused element is a
        // synchronous IPC into an app that may not answer, and the main actor
        // is holding the HUD.
        let target = await FocusedTarget.capture()
        self.logger.info("Focused target: bundle=\(target.bundleID ?? "nil", privacy: .public) secure=\(target.isSecureInput)")
        // Record first. If the target is secure, unavailable, or the
        // pasteboard fails, the completed text is already durable.
        let historyID = self.recordHistory(text: text, target: target)
        let result = await self.injector.inject(text, target: target)
        if let historyID {
          self.updateHistoryDelivery(historyID, result: result)
        }
        await MainActor.run {
          switch result {
          case .refused(let reason):
            self.state = .failed(message: reason)
            Task {
              try? await Task.sleep(nanoseconds: 2_000_000_000)
              await MainActor.run {
                self.injector.clearSecureFieldNotice()
                self.state = .idle
              }
            }
          case .failed(_, let reason):
            self.state = .failed(message: reason)
          case .delivered, .attempted:
            self.state = .idle
          }
          self.speechStream = nil
        }
      }
    } else {
      self.state = .idle
      self.speechStream = nil
    }
  }

  private func cancelSession() {
    speechStream?.cancel()
    speechStream = nil
    capture.stop()
    lastCaptureDiagnostics = capture.diagnostics
    resetStreamingSession()
    // The card itself is left alone: a permission that dropped mid-session is
    // no reason to throw away text the owner has already reviewed. It just
    // stops claiming to be listening, and its buttons come back.
    endReviewRecording()
  }

  // MARK: - History actions

  func copyDictationHistory(_ id: UUID) {
    guard let entry = historyStore.entry(id: id) else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if pasteboard.setString(entry.text, forType: .string) {
      historyNotice = "Copied dictation"
    } else {
      historyNotice = "Could not copy dictation"
    }
  }

  func deleteDictationHistory(_ id: UUID) {
    historyStore.delete(id: id)
    syncDictationHistory()
    historyNotice = "Dictation removed"
  }

  func clearDictationHistory() {
    historyStore.clear()
    syncDictationHistory()
    historyNotice = "Dictation history cleared"
  }

  /// Retry a selected entry against its original process when that process is
  /// still alive. Otherwise use the currently focused app, but refuse to send
  /// text back into Nota itself.
  func retryDictationHistory(_ id: UUID) {
    guard let entry = historyStore.entry(id: id), !entry.text.isEmpty else { return }
    historyNotice = "Retrying insertion…"
    state = .injecting

    Task {
      let target = await retryTarget(for: entry)
      guard let target else {
        let reason = "Open the app where you want the dictation inserted, then try again."
        updateHistoryDelivery(id, status: .failed, detail: reason)
        historyNotice = reason
        state = .failed(message: reason)
        return
      }

      historyStore.update(
        id: id,
        status: .pending,
        statusDetail: "Retrying insertion",
        targetBundleID: target.bundleID,
        targetProcessID: target.processID.map { Int32($0) }
      )
      syncDictationHistory()
      let result = await injector.inject(entry.text, target: target)
      updateHistoryDelivery(id, result: result)

      switch result {
      case .refused(let reason), .failed(_, let reason):
        historyNotice = reason
        state = .failed(message: reason)
      case .delivered, .attempted:
        historyNotice = "Insertion attempted"
        state = .idle
      }
    }
  }

  private func retryTarget(for entry: DictationHistoryEntry) async -> FocusedTarget? {
    if let rawPID = entry.targetProcessID {
      let pid = pid_t(rawPID)
      if pid != ProcessInfo.processInfo.processIdentifier,
         let app = NSRunningApplication(processIdentifier: pid),
         entry.targetBundleID == nil || app.bundleIdentifier == entry.targetBundleID {
        return FocusedTarget(
          bundleID: app.bundleIdentifier ?? entry.targetBundleID,
          isSecureInput: false,
          accessibilityElement: nil,
          processID: pid
        )
      }
    }

    let current = await FocusedTarget.capture()
    guard current.processID != ProcessInfo.processInfo.processIdentifier else { return nil }
    return current.processID == nil ? nil : current
  }

  deinit {
    if let launchObserver {
      NotificationCenter.default.removeObserver(launchObserver)
    }
    if let activationObserver {
      NotificationCenter.default.removeObserver(activationObserver)
    }
  }
}

#if DEBUG
// MARK: - Test seams

/// Same-file extension so the session state stays private to everything except
/// the tests that have to drive a recognizer that is not there. Session state
/// is normally written only by `start()`, which needs a microphone, an analyzer
/// and a permission grant; the claim under test — a review session accumulates
/// segments and delivers nothing — needs none of them.
extension DictationController {
  /// The state a session is left in once its recognizer has started, wired the
  /// way `start()` wires it: the plan for this controller's delivery mode
  /// decides both the live draft and whether a delivery queue exists at all.
  ///
  /// Running the plan here rather than setting `isLiveDraftSession` by hand is
  /// what makes "a review session builds no delivery queue" an assertion about
  /// the mode. A hook that never built one would answer nil in every mode, and
  /// a regression that wired review to a queue — sentences typed into the live
  /// document mid-session, the one thing this mode promises never to do — would
  /// leave the test green.
  ///
  /// The engine defaults to **this controller's own setting**, the way `start()`
  /// reads it, and not to `.apple`. A hard-coded default made the seam disagree
  /// with the session it stands in for: a test that saved
  /// `engine = .assemblyAIRealtime` and called this got a plan built for Apple,
  /// so `wantsLiveDraft` was false, no hypothesis was ever folded into the
  /// draft, and the failure read as a broken live-draft fold in production code
  /// that was in fact correct.
  func beginSessionForTests(engine: EngineChoice? = nil, target: FocusedTarget? = nil) {
    let plan = DictationSessionPlan.make(
      mode: settings.deliveryMode,
      engine: engine ?? settings.engine
    )
    // Exactly where `beginCaptureAndSpeech` does it, and for the same reason
    // the plan is run here rather than faked: in `.review` the card IS the
    // session's surface from the press onwards, so a seam that skipped this
    // would let a regression back into two-surface behaviour unnoticed.
    beginOrOpenReviewCard()
    isLiveDraftSession = plan.wantsLiveDraft
    roughDraft = ""
    finalizedDraft = ""
    segmenter = SentenceSegmenter()

    if plan.capturesTarget { sessionTarget = target }
    if plan.deliversMidSession, let target, !target.isSecureInput {
      deliveryQueue = makeDeliveryQueue(target: target, terms: [], snapshot: .empty)
    }
    isStreamingSession = deliveryQueue != nil && plan.wantsLiveDraft
  }

  /// Everything the recognizer has finalized this session.
  var recognizedSoFarForTests: String { finalizedDraft }

  /// Raise a session failure the way the live paths do — through `state`, which
  /// is the one place the card's error line is fed from. Setting the card's
  /// message directly would test the assignment and not the routing.
  func failForTests(_ message: String) { state = .failed(message: message) }

  /// The epoch a hypothesis from the current session would carry.
  var sessionEpochForTests: UInt64 { sessionEpoch }

  /// End the session the way teardown does — the epoch bump included, which is
  /// what makes a hypothesis stamped with the old one stale.
  func endSessionForTests() { resetStreamingSession() }

  /// Whether this session has anywhere to deliver text mid-session.
  var deliversMidSessionForTests: Bool { deliveryQueue != nil }

  /// Identity of the open review. Unchanged across a continuation (extended)
  /// and different after a replacement (superseded) — the distinction every
  /// late decision is judged by.
  var pendingReviewIDForTests: UUID? { pendingReview?.id }

  /// How many sessions have added to the open review.
  var pendingReviewGenerationForTests: Int? { pendingReview?.generation }

  /// The pid the open review would inject through. Newest capture wins.
  var pendingReviewTargetPIDForTests: pid_t? { pendingReview?.target?.processID }

  /// The batch as the pipeline produced it, before any owner edit — the
  /// `before` side of what Apply learns from.
  var pendingReviewPolishedForTests: String? { pendingReview?.polished }
  var pendingReviewOfflineForTests: String? { pendingReview?.offline }
}
#endif
