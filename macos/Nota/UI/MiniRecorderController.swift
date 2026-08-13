import AppKit
import Combine
import SwiftUI

// MARK: - The seam

/// What a ⌘K produced, as facts rather than as the model's own object.
struct IslandMarkResult: Equatable {
  /// Seconds into the session.
  let at: TimeInterval
  /// Which moment of the session this was — 1 for the first.
  let ordinal: Int
  /// Whether the press reached the record on disk.
  let landed: Bool
}

/// Everything `refresh()` reads about the world, in one value.
///
/// A snapshot rather than a `NotaModel` reference for one reason: `NotaModel
/// .init` sweeps the real `~/.nota` and runs preflight, so no test in this
/// bundle can build one — which used to mean the whole of this controller (the
/// routing, the handoff detection, the failure latch, the ticking) was asserted
/// nowhere at all.
@MainActor
struct IslandSource {
  var sessionState: LiveMeetingSession.SessionState
  /// A **Stop** handed a record to background processing. Deliberately not the
  /// shared "we left the live pane" flag — see `NotaModel.isLiveHandoffProcessing`.
  var isHandoffProcessing: Bool
  var elapsed: TimeInterval
  var level: MicLevelFeed?

  static func live(model: NotaModel) -> IslandSource {
    IslandSource(
      sessionState: model.liveSession.state,
      isHandoffProcessing: model.isLiveHandoffProcessing,
      elapsed: model.liveSession.elapsed,
      level: model.liveSession.level
    )
  }
}

/// The things an island (or menu-bar) press does, as one table of closures.
///
/// A seam, and it exists for the reason
/// `testEachCapsuleRunsItsOwnJobAndNoOtherCapsulesJob` exists: **which control
/// does what is precisely the thing that ships wrong**, and it shipped wrong
/// once already on the recording cluster. Before this, swapping the `.stop` and
/// `.show` bodies left every test in the island's file green — the red capsule
/// would have brought Nota forward while the session kept recording.
@MainActor
struct IslandVerbs {
  var mark: () -> IslandMarkResult?
  /// Stop capturing without ending the session, and start again (XIA-447).
  /// Two closures rather than one toggle, so a swapped body is a test failure
  /// rather than a surface that happens to still work.
  var pause: () -> Void = {}
  var resume: () -> Void = {}
  var stop: () -> Void
  var show: () -> Void
  var retry: () -> Void
  /// The island could not be put on screen after one recreate. Said where the
  /// owner is already looking, because there is no island to say it on.
  var reportUnavailable: () -> Void

  static func live(model: NotaModel) -> IslandVerbs {
    IslandVerbs(
      mark: {
        guard let marker = model.markCurrentMoment() else { return nil }
        // `markersUnsaved` is published by the press itself, so this is the
        // press's own answer and not a stale one. A ⌘K whose write did not
        // reach the record must not be congratulated.
        return IslandMarkResult(
          at: marker.at,
          ordinal: model.sessionMarkers.markers.count,
          landed: !model.markersUnsaved
        )
      },
      pause: { model.pauseLiveSession() },
      resume: { model.resumeLiveSession() },
      stop: { model.stopLiveSession() },
      // The ONE call on this path that brings Nota forward, and it is the owner
      // pressing a button labelled "Show". Nothing about *presenting* the island
      // activates the app — that is the rule, and this is not presentation.
      show: { NotificationCenter.default.post(name: .notaShowLiveRecord, object: nil) },
      retry: {
        // Forward FIRST, and then start. `startLiveSession` goes through
        // `requestSummaryRailDismissal`, whose `.ask` branch parks the start and
        // raises a confirm sheet **in the main window** — which is behind
        // whatever the owner is looking at, since the island is only up when
        // Nota is not frontmost. Ungated, Try Again was a button that did
        // nothing at all and offered no way to find out why. Starting again is
        // also a request to be back in the live pane, so this is not a
        // concession: it is what the press means.
        NotificationCenter.default.post(name: .notaShowLiveRecord, object: nil)
        // The **kind**, not the default: a failed memo retried as a meeting
        // would carry the wrong kind and the wrong diarize/identify flags.
        model.startLiveSession(kind: model.activeSessionKind)
      },
      reportUnavailable: { model.reportIslandUnavailable() }
    )
  }
}

// MARK: - The controller

/// Drives the mini-recorder island from the model, and nothing else drives it.
///
/// The decisions are all in pure types (`MiniIslandVisibility`,
/// `MiniIslandPhase`, `MiniIslandMetrics`); this is the plumbing that feeds them
/// — what changed, what time it is, and whether Nota is in front.
///
/// **Frontmost is read at decision time and never cached** (the rule
/// `CompletionNotifier.appIsFrontmost` already keeps): the owner may have
/// switched away since the last notification, and a stale answer is either two
/// live indicators for one microphone or none.
@MainActor
final class MiniRecorderIslandController {
  private let presenter: MiniRecorderPresenting
  private let frontmost: @MainActor () -> Bool
  private let clock: () -> TimeInterval
  /// The owner's glass settings, read when a card goes up. Injectable so a test
  /// does not depend on the machine's saved preferences.
  private let settings: () -> DictationSettings

  private var source: (@MainActor () -> IslandSource)?
  private var verbs: IslandVerbs?
  private var sinks: [AnyCancellable] = []
  private var ticker: Timer?

  /// The last ⌘K the island acknowledged, and when Stop was pressed. Both are
  /// island state rather than model state: they are about what this surface is
  /// saying, and the record already holds the moments and the status.
  private(set) var mark: MiniIslandMark?
  private(set) var handoffStartedAt: TimeInterval?

  /// One failed presentation per session, and no more.
  ///
  /// `reportUnavailable` writes `NotaModel.status`, which is `@Published` and
  /// therefore republishes on every assignment — and this controller subscribes
  /// to `model.objectWillChange`. Without the latch the report fed straight back
  /// into the code that made it: another `refresh()`, another `show()` (the
  /// presenter is not presenting, so it takes the same branch), **two** fresh
  /// `NSPanel`s and hosting views per iteration, forever, on the main actor,
  /// during a live recording. The presenter's own comment says the answer is to
  /// say so rather than to keep building panels; this is what makes that true of
  /// the caller. Cleared when the island next has no reason to be up, so the
  /// next session asks the window server again.
  private(set) var reportedUnavailable = false

  /// `presenter` is optional rather than defaulted to a real one: a default
  /// argument expression is evaluated in a nonisolated context, and the real
  /// presenter is main-actor isolated. Same shape as
  /// `DictationController.init(review:)`.
  init(
    presenter: MiniRecorderPresenting? = nil,
    frontmost: (@MainActor () -> Bool)? = nil,
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    settings: @escaping () -> DictationSettings = { DictationSettingsStore.load() },
    /// Injected by tests only. `start(model:)` installs the live pair when these
    /// are nil, and leaves injected ones alone.
    source: (@MainActor () -> IslandSource)? = nil,
    verbs: IslandVerbs? = nil
  ) {
    self.presenter = presenter ?? MiniRecorderPresenter()
    // `NSApp.isActive`, read at decision time and never cached — the same rule
    // `CompletionNotifier.appIsFrontmost` keeps, and the reason it is a closure
    // is that a test has no NSApplication to be active.
    self.frontmost = frontmost ?? { NSApp?.isActive ?? false }
    self.clock = clock
    self.settings = settings
    self.source = source
    self.verbs = verbs
  }

  /// Idempotent — the menu-bar label's `onAppear` is the one caller, and it is
  /// the surface that exists for the whole life of the process (the document
  /// window can be closed; the status item cannot).
  func start(model: NotaModel) {
    guard sinks.isEmpty else { return }
    if source == nil { source = { IslandSource.live(model: model) } }
    if verbs == nil { verbs = .live(model: model) }

    // Two publishers, both coarse. The session's own changes carry state and
    // the once-a-second `elapsed`; the model's carry the handoff flag. The
    // microphone's ~15 Hz feed is NOT among them — it is handed to the meter's
    // leaf view as a plain reference (XIA-432).
    sinks.append(
      model.liveSession.objectWillChange
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refresh() }
    )
    sinks.append(
      model.objectWillChange
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.refresh() }
    )
    for name in [
      NSApplication.didBecomeActiveNotification,
      NSApplication.didResignActiveNotification,
    ] {
      sinks.append(
        NotificationCenter.default.publisher(for: name)
          .receive(on: DispatchQueue.main)
          .sink { [weak self] _ in self?.refresh() }
      )
    }
    refresh()
  }

  /// What the island would show right now. Internal so the rule can be driven
  /// end to end from a test with a stub presenter — the shape
  /// `DictationController.deliver` is internal for.
  func inputs() -> MiniIslandInputs {
    guard let source = source?() else { return MiniIslandInputs(now: clock()) }
    return MiniIslandInputs(
      sessionState: source.sessionState,
      appIsFrontmost: frontmost(),
      mark: mark,
      handoffStartedAt: handoffStartedAt,
      now: clock()
    )
  }

  func refresh() {
    guard let source = source?() else { return }
    trackHandoff(source)

    let inputs = self.inputs()
    guard let phase = MiniIslandVisibility.phase(inputs) else {
      presenter.dismiss()
      // Nothing is asking for an island, so the next thing that does gets a
      // fresh attempt at the window server.
      reportedUnavailable = false
      stopTicking()
      return
    }

    let render = MiniIslandRender(
      phase: phase,
      elapsed: source.elapsed,
      level: source.level
    )
    if presenter.isPresenting {
      presenter.update(render)
    } else if reportedUnavailable {
      // Already asked once for this session, and the owner has been told.
      // Asking again is the loop the latch exists to stop.
      stopTicking()
      return
    } else {
      applyGlassSettings()
      if !presenter.show(render, perform: { [weak self] in self?.perform($0) }) {
        // A card that never reached the screen is this surface's whole output
        // missing. There is nowhere on the island to say so, so it is said
        // where the owner is already looking — **once**.
        reportedUnavailable = true
        verbs?.reportUnavailable()
        stopTicking()
        return
      }
    }
    scheduleTick(inputs)
  }

  /// The owner's Glass opacity and material, read at the moment a card goes up.
  ///
  /// That moment is enough, and it is not a shortcut: the slider is in
  /// Settings, Settings means Nota is frontmost, and Nota being frontmost means
  /// the island is down — so every change to those two values is followed by a
  /// fresh `show`. Without this the HUD and the review card obeyed the slider
  /// and the island alone stayed at the default, with no code path that would
  /// ever have changed it.
  private func applyGlassSettings() {
    let current = settings()
    presenter.glassTintAlpha = current.hudGlassOpacity
    presenter.glassMaterial = current.hudGlassMaterial
  }

  /// Detect the Stop press — **the Stop press specifically**, not the shared
  /// "we left the live pane" flag.
  ///
  /// `NotaModel.isLiveSessionHandedOff` is set by `discardLiveSession` too, and
  /// Discard hands nothing off: it deletes the record and its audio (XIA-436).
  /// Reading that flag had the island announce "Transcribing… 3s ago" with a
  /// Show button, over another app, for a session whose recording had just been
  /// deleted — the one thing this surface may not do is claim work is in flight
  /// on something that is gone.
  private func trackHandoff(_ source: IslandSource) {
    if source.isHandoffProcessing {
      if handoffStartedAt == nil {
        handoffStartedAt = clock()
        // A handoff supersedes a mark confirmation: the session it belonged to
        // is over.
        mark = nil
      }
    } else {
      handoffStartedAt = nil
    }
  }

  // MARK: - The verbs

  /// Every press from every surface that offers these verbs — the island's
  /// capsules AND the menu bar's rows — lands here. **One switch**, so "⌘K
  /// means one thing wherever it is pressed" is a fact rather than two
  /// implementations that happen to agree today.
  func perform(_ action: MiniIslandAction) {
    guard let verbs else { return }
    switch action {
    case .mark:
      if let result = verbs.mark() {
        mark = MiniIslandMark(
          at: result.at,
          ordinal: result.ordinal,
          landed: result.landed,
          pressedAt: clock()
        )
      }
    case .pause:
      verbs.pause()
    case .resume:
      verbs.resume()
    case .stop:
      verbs.stop()
    case .show:
      verbs.show()
    case .retry:
      verbs.retry()
    }
    refresh()
  }

  // MARK: - Ticking

  /// Wake for the next thing that expires, and not otherwise. The recording
  /// phase needs no timer at all — `LiveMeetingSession.elapsed` publishes about
  /// once a second and `refresh()` rides that.
  private func scheduleTick(_ inputs: MiniIslandInputs) {
    guard let deadline = MiniIslandVisibility.nextDeadline(inputs) else {
      stopTicking()
      return
    }
    stopTicking()
    let delay = max(deadline - inputs.now, 0.05)
    ticker = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
  }

  private func stopTicking() {
    ticker?.invalidate()
    ticker = nil
  }
}

extension Notification.Name {
  /// The island's Show: bring the main window forward onto the record that is
  /// being worked on. Handled by `AppDelegate`, which is alive for the whole
  /// life of the process — a subscriber inside the WindowGroup's content does
  /// not exist when there is no window, which is the case the island is for.
  static let notaShowLiveRecord = Notification.Name("NotaShowLiveRecord")
}
