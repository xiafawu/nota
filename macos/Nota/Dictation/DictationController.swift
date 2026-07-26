import AppKit
import Foundation
import os

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
  /// The recognizer's un-finalized tail during a streaming session — the rough
  /// draft the HUD shows. Always empty when streaming delivery is off.
  @Published private(set) var roughDraft: String = ""
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
  /// Where this session's text goes, captured when the hotkey went down.
  private var streamingTarget: FocusedTarget?
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

  init(
    permissions: PermissionsCoordinator? = nil,
    capture: MicCapture? = nil,
    hotkeyMonitor: HotkeyMonitor? = nil
  ) {
    self.settings = DictationSettingsStore.load()
    self.permissions = permissions ?? PermissionsCoordinator()
    self.capture = capture ?? MicCapture()
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

    isSessionPending = true

    // Streaming appends into whatever had focus when the hotkey went down, and
    // keeps appending there for the whole session. Capturing at the end
    // instead — as batch delivery does — would send a sentence the user
    // started in one app into whatever they switched to while it was being
    // polished. Text already typed into a document cannot be moved.
    //
    // Restricted to the Apple engine: AssemblyAI realtime reports whole turns
    // rather than deltas, so its "finals" are not segments.
    let wantsStreaming = settings.streamingDelivery && settings.engine == .apple

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
      let target = wantsStreaming ? await FocusedTarget.capture() : nil
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
        streaming: wantsStreaming
      )
      self.speechStream = stream
      self.logger.info("Using engine: \(self.settings.engine.label)")
      self.logger.debug(
        "Session context: app=\(snapshot.appName ?? "nil", privacy: .public) hints=\(hints.count)"
      )

      // The delivery queue must exist before the hypothesis loop starts, or a
      // segment arriving early would have nowhere to go.
      if wantsStreaming, let startTarget {
        if startTarget.isSecureInput {
          // Batch delivery refuses secure fields with a notice at the end;
          // streaming would have to refuse once per sentence instead.
          self.logger.notice("Streaming delivery skipped — focused field is secure")
        } else {
          self.streamingTarget = startTarget
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

      // Only now is it known whether the engine that actually started can
      // report segments — a SpeechAnalyzer session that fell back to
      // SFSpeechRecognizer cannot, and this session reverts to batch delivery.
      self.isStreamingSession = self.deliveryQueue != nil && stream.deliversSegments
      if wantsStreaming, !self.isStreamingSession {
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

        let textToInject: String

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
              self.doInject(rulesResult, latency: latency)
              return
            }

            self.doInject(polished, latency: latency)
            // After injection, never before: learning is bookkeeping and must
            // not delay the text reaching the user's cursor.
            self.learnFromPolish(before: rulesResult, after: polished)
          }
        } else {
          textToInject = rulesResult
          self.doInject(textToInject, latency: latency)
        }
      }
    }
  }

  // MARK: - Hypothesis routing

  /// One hypothesis from the recognizer.
  ///
  /// With streaming off this is exactly what it has always been: record the
  /// text for diagnostics. Streaming adds two arrivals — a finalized *segment*
  /// (a delta, feed it to the segmenter) and a volatile tail (replace the
  /// rough draft) — and never rewrites what an earlier segment delivered.
  private func handleHypothesis(_ hypothesis: Hypothesis) {
    if hypothesis.isSegment {
      streamingRecognized = StreamingDelivery.joined(streamingRecognized, hypothesis.text)
      lastHypothesis = streamingRecognized
      logger.debug("Segment finalized: \"\(hypothesis.text, privacy: .public)\"")
      guard let deliveryQueue else { return }
      for segment in segmenter.append(hypothesis.text) {
        deliveryQueue.enqueue(segment)
      }
      return
    }

    if isStreamingSession {
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

    let refine: StreamingDeliveryQueue.Refine = { [weak self] segment in
      // A fragment never reaches polish, so it never counts as polish in
      // flight either.
      let willPolish = polish != nil && segment.isWholeSentence
      if willPolish { await self?.beginPolish() }
      let refined = await StreamingDelivery.refine(segment, terms: terms, polish: polish)
      if willPolish { await self?.endPolish(refined) }
      return refined.text
    }

    let deliver: StreamingDeliveryQueue.Deliver = { [weak self] delta in
      guard let self else { return }
      await self.injector.inject(delta, target: target, mode: .append)
    }

    return StreamingDeliveryQueue(refine: refine, deliver: deliver)
  }

  private func beginPolish() {
    polishInFlight += 1
    isPolishInProgress = true
  }

  private func endPolish(_ refined: StreamingDelivery.RefinedSentence) {
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
    learnFromPolish(before: refined.offline, after: refined.text)
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

      self.finishStreamingSession(error: finishError)
    }
  }

  /// Wait for the hypothesis loop to end, but never longer than `timeout`.
  ///
  /// The recognizer's results stream normally ends inside `finish()`, which
  /// ends the hypothesis stream with it. When the analyzer stalls and the
  /// stream's own watchdog returns instead, nothing ever ends it — so the loop
  /// is cancelled rather than waited on forever.
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

  private func finishStreamingSession(error: (any Error)?) {
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

  private func resetStreamingSession() {
    hypothesisTask = nil
    deliveryQueue = nil
    streamingTarget = nil
    isStreamingSession = false
    segmenter = SentenceSegmenter()
    streamingRecognized = ""
    roughDraft = ""
  }

  /// Record identifiers the polish model corrected, so the next session gets
  /// them at L1/L2 without a paid call.
  ///
  /// Runs off the main actor: `DictionaryStore` writes atomically, so a
  /// background write racing a foreground read can only ever produce the old or
  /// the new file, never a half-written one. A write failure is logged and
  /// dropped — learning is an optimization, never a reason to surface an error
  /// after the text has already been injected.
  private func learnFromPolish(before: String, after: String) {
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
