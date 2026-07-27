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
    // Only the Apple analyzer reports deltas. AssemblyAI realtime reports whole
    // formatted turns, so asking it for a live draft yields neither a volatile
    // tail worth showing nor segments worth accumulating.
    let live = engine == .apple && (mode == .streaming || mode == .review)
    return DictationSessionPlan(
      wantsLiveDraft: live,
      // Streaming appends into whatever had focus when the hotkey went down and
      // keeps appending there for the whole session. Review appends nothing at
      // all until the owner says so.
      deliversMidSession: mode == .streaming && live,
      // Review captures the same target for the opposite reason streaming does:
      // nothing is delivered during the session, and by the time the owner
      // applies, the session that recognized the audio is long over. Engine
      // independent — the pid is needed however the audio was recognized.
      capturesTarget: mode == .review || (mode == .streaming && live)
    )
  }
}

@MainActor
final class DictationController: ObservableObject {
  @Published private(set) var state: DictationState = .disabled(reason: "Checking permissions…")
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
  private var hypothesisTask: Task<Void, Never>?
  /// Everything the recognizer has finalized this session, for diagnostics.
  private var streamingRecognized = ""
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
    let id = UUID()
    /// What the panel was opened with (polished, or the offline text when
    /// polish is off or failed).
    let polished: String
    /// The rules + dictionary result behind `polished`.
    let offline: String
    /// The target captured when the hotkey went down.
    let target: FocusedTarget?
    let latency: TimeInterval
  }

  private var pendingReview: PendingReview? {
    didSet { isReviewing = pendingReview != nil }
  }
  private let review: any DictationReviewPresenting

  /// How long Apply waits after the card goes away before posting keystrokes,
  /// so the target app's own window has key status back. See `injectReviewed`.
  private static let reviewKeyRestoreSettleNs: UInt64 = 80_000_000

  init(
    permissions: PermissionsCoordinator? = nil,
    capture: MicCapture? = nil,
    hotkeyMonitor: HotkeyMonitor? = nil,
    review: (any DictationReviewPresenting)? = nil
  ) {
    self.settings = DictationSettingsStore.load()
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

    // The panel belongs to the session that produced its text: a new one
    // cancels it, and cancelling inserts nothing.
    discardPendingReview()

    isSessionPending = true

    // What this session asks the recognizer for, and what it is allowed to do
    // with the results. Review and streaming share the live recognizer and
    // share nothing else: review accumulates and delivers exactly once, at the
    // end, into the panel.
    let plan = DictationSessionPlan.make(mode: settings.deliveryMode, engine: settings.engine)

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
      async let snapshot = ContextSnapshot.capture()
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
        "Session context: app=\(snapshot.appName ?? "nil", privacy: .public) hints=\(hints.count)"
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
      self.hypothesisTask = Task { [weak self] in
        guard let self else { return }
        for await hypothesis in stream.hypotheses {
          await MainActor.run {
            self.handleHypothesis(hypothesis)
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
        self.state = .failed(message: error.localizedDescription)
        self.logger.error("SpeechStream.start failed: \(error.localizedDescription, privacy: .public)")
        return
      }

      // Only now is it known what the engine that actually started can do — a
      // SpeechAnalyzer session that fell back to SFSpeechRecognizer reports
      // finality once, at the end, so it has neither a live draft nor segments.
      self.isLiveDraftSession = stream.deliversSegments
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
          self.state = .idle
          self.speechStream = nil
        }
        return
      } catch {
        await MainActor.run {
          self.isSessionPending = false
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
          let context = self.sessionContext

          Task {
            let polished: String
            do {
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
              self.logger.warning("Polish failed: \(error.localizedDescription, privacy: .public)")
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
      streamingRecognized = StreamingDelivery.joined(streamingRecognized, hypothesis.text)
      lastHypothesis = streamingRecognized
      logger.debug("Segment finalized: \"\(hypothesis.text, privacy: .public)\"")
      // The volatile tail this finalized: the HUD must stop offering it as a
      // rough draft of text that is already recognized. No further volatile
      // result is guaranteed to arrive and clear it.
      roughDraft = ""
      guard let deliveryQueue else { return }
      for segment in segmenter.append(hypothesis.text) {
        deliveryQueue.enqueue(segment)
      }
      return
    }

    if isLiveDraftSession {
      roughDraft = hypothesis.text
      return
    }

    lastHypothesis = hypothesis.text
    logger.debug("Hypothesis isFinal=\(hypothesis.isFinal) text=\"\(hypothesis.text, privacy: .public)\"")
  }

  // MARK: - Streaming delivery

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

    let runPolish: @Sendable (String) async throws -> String = { text in
      try await PolishClient.polish(
        text,
        modelID: modelID,
        vocabulary: vocabulary,
        context: snapshot
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
      await self.injector.inject(delta, target: target, mode: .append)
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
      logger.warning("Polish failed: \(error.localizedDescription, privacy: .public)")
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
    sessionTarget = nil
    isStreamingSession = false
    isLiveDraftSession = false
    segmenter = SentenceSegmenter()
    streamingRecognized = ""
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
      doInject(text, latency: latency)
      return
    }
    presentReview(polished: text, offline: offline, latency: latency)
  }

  /// Open the review panel on this session's text.
  private func presentReview(polished: String, offline: String, latency: TimeInterval) {
    isPolishInProgress = false
    speechStream = nil
    lastLatency = latency
    // Nothing has reached the target app, so nothing may read as inserted —
    // the HUD's success snippet comes from this field, and the last session's
    // text is still in it.
    lastProcessedText = nil

    guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      // Nothing was recognized; an empty panel is worse than no panel.
      state = .idle
      return
    }

    // Anything still open belongs to an earlier session; close it out first so
    // its decision cannot be attributed to this one.
    discardPendingReview()

    let pending = PendingReview(
      polished: polished,
      offline: offline,
      target: sessionTarget,
      latency: latency
    )
    pendingReview = pending
    state = .idle

    let id = pending.id
    let shown = review.present(
      DictationReviewRequest(
        text: polished,
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
      logger.error("Review panel could not be shown — the session's text was not inserted")
      state = .failed(message: "Nota could not show the review card. Restart Nota to fix it.")
      return
    }
    logger.info("Review panel opened with \(polished.count) characters")
  }

  /// Close an open review as a discard. Nothing is inserted.
  private func discardPendingReview() {
    guard let pending = pendingReview else { return }
    finishReview(.discard, id: pending.id)
  }

  /// Land a review decision.
  ///
  /// `id` is the same guard the streaming epoch is: the panel outlives the
  /// session that filled it, and a decision that arrives after another session
  /// has taken over must not be attributed to that session's text or target.
  private func finishReview(_ decision: DictationReview.Decision, id: UUID) {
    guard let pending = pendingReview, pending.id == id else { return }
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
      logger.info("Review discarded — nothing inserted")
      state = .idle
      return
    }

    injectReviewed(text, target: pending.target, latency: pending.latency)
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
  private func injectReviewed(_ text: String, target: FocusedTarget?, latency: TimeInterval) {
    // A pid is required, and it may not be Nota's own. Injecting "wherever" is
    // exactly the failure this mode exists to prevent, so it refuses instead —
    // the text stays on the owner's screen in the panel they applied from.
    guard let target,
          let pid = target.processID,
          pid != ProcessInfo.processInfo.processIdentifier
    else {
      logger.error("Reviewed text has no usable target — refusing to insert it anywhere")
      state = .failed(message: "Nota lost track of the app you were dictating into.")
      return
    }

    lastProcessedText = text
    state = .injecting
    logger.info(
      "Review applied: latency=\(String(format: "%.2f", latency))s text=\"\(text, privacy: .public)\""
    )

    Task {
      // The card that just ordered out was the KEY window. It never activated
      // Nota — the target app stayed frontmost the whole time — but its own
      // window resigned key while the owner typed in the card, and AppKit hands
      // key status back through the window server a beat after the panel goes.
      // Two of the three injection strategies post keystrokes to the target's
      // pid (`tryCGEventInject`, and the paste strategy's synthetic Cmd-V), and
      // an app routes those to whatever its key window is at delivery time: post
      // them into that gap and Chrome, Slack, VSCode and every terminal —
      // exactly the apps `defaultOverrideTable` forces down those two paths —
      // drop them, while `lastProcessedText` still claims a success. AX writing
      // does not care; the wait is imperceptible and covers all three.
      try? await Task.sleep(nanoseconds: Self.reviewKeyRestoreSettleNs)
      await self.injector.inject(text, target: target)
      if let notice = self.injector.lastSecureFieldNotice {
        self.state = .failed(message: notice)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        self.injector.clearSecureFieldNotice()
        self.state = .idle
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
        await self.injector.inject(text, target: target)
        await MainActor.run {
          if let notice = self.injector.lastSecureFieldNotice {
            self.state = .failed(message: notice)
            Task {
              try? await Task.sleep(nanoseconds: 2_000_000_000)
              await MainActor.run {
                self.injector.clearSecureFieldNotice()
                self.state = .idle
              }
            }
          } else {
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
  /// The state a live-draft session is left in once its recognizer has started.
  func beginLiveDraftSessionForTests() {
    isLiveDraftSession = true
    roughDraft = ""
    streamingRecognized = ""
    segmenter = SentenceSegmenter()
  }

  /// Everything the recognizer has finalized this session.
  var recognizedSoFarForTests: String { streamingRecognized }

  /// Whether this session has anywhere to deliver text mid-session.
  var deliversMidSessionForTests: Bool { deliveryQueue != nil }
}
#endif
