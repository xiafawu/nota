import Foundation
import os

// MARK: - What live naming asks, and what may answer it

/// One finalized turn's audio — 16 kHz mono Int16, the shape everything else in
/// the live path already speaks — and nothing else. A request carries no text,
/// no segment id and no timestamp: the helper's whole job is "whose voice is
/// this", and a request that carried the words would be handing the transcript
/// to a process that has no business reading it.
struct VoiceprintRequest: Equatable {
  let samples: [Int16]
  let sampleRate: Int

  var seconds: TimeInterval { Double(samples.count) / Double(sampleRate) }
}

/// The seam between a live session and the thing that names its turns.
///
/// It exists so the whole of `LiveMeetingSession`'s naming path — the ring, the
/// one-request-at-a-time chain, the never-rewrite rule and every teardown — is
/// driven by a fake, with no child process, no ONNX model and no enrolled voice
/// anywhere near the test bundle. The production conformer is
/// `VoiceprintHelperProcess`.
///
/// `identify` answers nil for **every** way of not having a name: no confident
/// match, a turn too short to embed, a helper that never started, one that
/// answered `ready:false`, one that died mid-meeting, one that stopped
/// answering. That is deliberate rather than lossy — ADR 0008 draws a name only
/// for a confident match, so every one of those outcomes has the same
/// consequence on screen, and a caller that had to tell them apart would be a
/// caller that could get the degrade wrong.
@MainActor
protocol LiveVoiceprintNaming: AnyObject {
  /// Whether it is worth asking. False once the helper is stopped or has
  /// declined; true while it is still starting, because a turn that finalizes
  /// during model load is one worth queueing rather than discarding.
  var isRunning: Bool { get }

  /// Bring the helper up. Synchronous and non-throwing on purpose: a session
  /// may not wait on naming, and a spawn that fails is not an error anybody is
  /// told about — it is a meeting with no names.
  func start()

  func identify(_ request: VoiceprintRequest) async -> String?

  /// Idempotent, and safe from any exit path including one that runs twice.
  func stop()
}

// MARK: - The rule about writing a name

/// **A label once shown is never changed mid-meeting** (ADR 0008).
///
/// One line, in its own type, because it is a *decision* and not an
/// implementation detail of the write that honours it: the seal re-runs
/// diarization over the whole audio and is the authority, so a live correction
/// buys nothing the seal will not deliver, while a name flickering from one
/// person to another under the reader's eye is worse than one that is merely
/// incomplete.
enum LiveSpeakerAttribution {
  static func mayWrite(over existing: String?) -> Bool { existing == nil }
}

// MARK: - The turn ring

/// The most recent seconds of **kept** session audio, so a turn that has just
/// finalized can be sliced back out of it and sent.
///
/// Pure, and a value type, so every rule below is asserted without a
/// microphone: what a turn slice contains, that a paused span contributes
/// nothing (the session appends only what got past `capturesAudio`), and that a
/// turn too short to embed produces no request at all.
///
/// **It is sliced backwards from the write head, never from `elapsed`.** The
/// published clock is quantized to the 250 ms ticker and starts before the
/// first sample is captured, whereas the head is by construction the exact end
/// of the audio that was kept — the same audio `recording.caf` holds, frame for
/// frame. "The last N seconds" is therefore a question about the file; "the
/// span between two elapsed values" would be a question about a clock that only
/// approximates it.
struct LiveTurnAudioBuffer {
  /// The one rate the live path speaks, everywhere: `MicCapture` converts to
  /// it, the socket frames are it, `recording.caf` is written at it.
  static let sampleRate = 16_000

  /// The longest slice that is ever sent. A turn longer than this contributes
  /// its **last** `maxTurnSeconds` — still the same speaker, and the part least
  /// likely to have been clipped by the finalization boundary.
  static let maxTurnSeconds: TimeInterval = 12

  /// Below this, no request is made at all. The embedder raises
  /// `InsufficientSpeechError` for a clip with no frames, and ADR 0008 already
  /// accepts that a turn too short to embed stays blank live — so the cheap
  /// answer is to not spend a round trip on it.
  static let minimumTurnSeconds: TimeInterval = 1.0

  /// What a recognizer spends deciding a turn is over. Audio keeps arriving
  /// through it, so the ring has to hold the longest slice *plus* this or the
  /// head of a maximum-length turn would already have been evicted by the time
  /// anybody asked for it.
  static let finalizationMarginSeconds: TimeInterval = 3

  /// Composed from the two above, never typed — the `RecordingPaneMetrics
  /// .capsuleHeight` precedent: the bound is derived from the longest thing the
  /// ring must be able to answer.
  static var capacitySeconds: TimeInterval { maxTurnSeconds + finalizationMarginSeconds }
  static var capacitySamples: Int { Int(capacitySeconds * TimeInterval(sampleRate)) }

  /// How far past capacity the store may run before it is trimmed.
  ///
  /// Trimming on every delivery would `memmove` half a megabyte 45 times a
  /// second for the length of a meeting — exactly the audio-rate cost this
  /// feature is otherwise careful not to add. Trimming in blocks pays it about
  /// once a second instead, and all the slack changes is the resident size.
  static let trimSlackSeconds: TimeInterval = 2
  static var trimSlackSamples: Int { Int(trimSlackSeconds * TimeInterval(sampleRate)) }

  static var minimumSamples: Int { Int(minimumTurnSeconds * TimeInterval(sampleRate)) }

  /// Every sample ever appended, evicted or not. It is what makes "the paused
  /// span contributed nothing" a fact read off the ring rather than an
  /// inference from the audio inside it.
  private(set) var totalSamplesWritten = 0

  private var storage: [Int16] = []

  /// How much is held right now.
  var count: Int { storage.count }

  mutating func append(_ samples: UnsafeBufferPointer<Int16>) {
    guard !samples.isEmpty else { return }
    storage.append(contentsOf: samples)
    totalSamplesWritten += samples.count
    let capacity = Self.capacitySamples
    if storage.count > capacity + Self.trimSlackSamples {
      storage.removeFirst(storage.count - capacity)
    }
  }

  mutating func append(_ samples: [Int16]) {
    samples.withUnsafeBufferPointer { append($0) }
  }

  /// The last `seconds` of kept audio, or nil when there is not enough of it to
  /// be worth embedding.
  func slice(lastSeconds seconds: TimeInterval) -> [Int16]? {
    guard seconds >= Self.minimumTurnSeconds else { return nil }
    let wanted = Int((min(seconds, Self.maxTurnSeconds) * TimeInterval(Self.sampleRate)).rounded())
    let available = min(wanted, storage.count)
    guard available >= Self.minimumSamples else { return nil }
    return Array(storage.suffix(available))
  }

  /// Drop everything, so one meeting's audio can never be sliced into another
  /// meeting's first turn.
  mutating func reset() {
    storage.removeAll(keepingCapacity: false)
    totalSamplesWritten = 0
  }
}

// MARK: - The helper process

/// The long-running Node child that names live turns (ADR 0008,
/// `docs/voiceprint-helper-protocol.md`).
///
/// One process for a whole meeting, because the alternative — the
/// spawn-per-operation shape `EnrollQueue` uses — would reload a 27 MB ONNX
/// model every few seconds and trail the conversation for the length of the
/// session.
///
/// **Everything here degrades to silence.** A binary that is not there, a
/// helper that answers `ready:false`, one that dies in the middle, one that
/// stops answering: each ends with `identify` returning nil and the meeting
/// recording exactly as it would have without any of this. Nothing throws,
/// nothing is surfaced to the owner, and no path reaches the session's failure
/// machinery. Naming is a nicety; capturing the meeting is not.
///
/// The protocol's byte-level decisions are `static` and pure — `requestLine`,
/// `name(fromAnswer:)`, `launchPlan`, `readiness(fromLine:)`. The two halves of
/// this feature were built in parallel by separate agents, so concentrating
/// them means a divergence on the Node side is absorbed by editing four
/// functions and their tests, with none of the process plumbing below and
/// nothing in `LiveMeetingSession` having to move.
@MainActor
final class VoiceprintHelperProcess: LiveVoiceprintNaming {
  // MARK: - The contract, as pure functions

  /// The confident-match floor, mirroring `MATCH_THRESHOLD` in
  /// `src/pipeline/embed.ts`.
  ///
  /// **Re-checked on this side even though the helper applies it too.** ADR
  /// 0008's rule is that nothing on screen may be a guess, and the surface that
  /// draws the name is this one. A helper that shipped ahead of us, or one
  /// pointed at by `NOTA_VOICEPRINT_HELPER`, or one that simply answers with a
  /// tentative-band score, must not be able to put an unconfident name in front
  /// of the owner.
  static let matchThreshold: Double = 0.65

  /// Point the app at a different helper executable. The escape hatch for a
  /// Node half that diverges: it is run as-is, with no verb appended.
  static let executableOverrideVariable = "NOTA_VOICEPRINT_HELPER"

  /// The verb the CLI half answers to.
  /// One hyphenated command, not two words. The helper is registered on the
  /// CLI as `voiceprint-serve`; the two-word form in the first draft of
  /// `docs/voiceprint-helper-protocol.md` never existed on the far side.
  static let verb = ["voiceprint-serve"]

  static let requestTimeout: TimeInterval = 10

  struct LaunchPlan: Equatable {
    let executableURL: URL
    let arguments: [String]
    let currentDirectory: URL
  }

  /// What to spawn, in the preference order the protocol document fixes.
  /// Pure, so all three branches are asserted on a machine with no built
  /// `dist/` — the one that decides them is `fileExists`, injected.
  static func launchPlan(
    projectDirectory: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
  ) -> LaunchPlan {
    // Everything goes through `/usr/bin/env`, exactly as `EnrollQueue.spawn`
    // does, so `node`/`npx` are found on the owner's PATH rather than at a
    // hard-coded prefix that differs between Homebrew, nvm and Xcode.
    let env = URL(fileURLWithPath: "/usr/bin/env")
    if let override = environment[executableOverrideVariable], !override.isEmpty {
      return LaunchPlan(
        executableURL: env, arguments: [override], currentDirectory: projectDirectory
      )
    }
    let dist = projectDirectory
      .appendingPathComponent("dist")
      .appendingPathComponent("index.js")
    if fileExists(dist.path) {
      return LaunchPlan(
        executableURL: env,
        arguments: ["node", dist.path] + verb,
        currentDirectory: projectDirectory
      )
    }
    let source = projectDirectory
      .appendingPathComponent("src")
      .appendingPathComponent("index.ts")
    return LaunchPlan(
      executableURL: env,
      arguments: ["npx", "tsx", source.path] + verb,
      currentDirectory: projectDirectory
    )
  }

  /// The project the CLI lives in — the same resolution `EnrollQueue` uses.
  static var projectDirectory: URL {
    URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["NOTA_PROJECT_DIR"]
        ?? "/Users/xiafawu/Developer/Nota"
    )
  }

  /// `{"id":"…","op":"match","pcm":"<base64 Int16 LE>"}` plus a newline.
  ///
  /// The id crosses as a **string** and the op is named, because the helper's
  /// protocol carries both — it dispatches on `op` and echoes the id verbatim.
  /// The sample rate does not cross at all: 16 kHz mono is the only thing the
  /// capture path produces and the helper asserts it on its own side, so a
  /// field naming it would be a second place for one fact to be wrong.
  static func requestLine(id: Int, request: VoiceprintRequest) -> Data? {
    let payload: [String: Any] = [
      "id": String(id),
      "op": "match",
      "pcm": pcmBase64(request.samples),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    return data + Data([0x0A])
  }

  /// Int16 little-endian — what the contract names, and what every machine this
  /// runs on is anyway. Written explicitly so the byte order is a property of
  /// the encoder rather than of the architecture.
  static func pcmBase64(_ samples: [Int16]) -> String {
    let littleEndian = samples.map { $0.littleEndian }
    return littleEndian.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
  }

  /// The name an answer line yields, with **every** "no name" collapsed to nil:
  /// a null or absent `name`, an `error`, an empty string, and a score below
  /// the threshold. There is no unfiltered value to read, so a caller cannot
  /// forget to apply the rule.
  static func name(fromAnswer json: [String: Any]) -> String? {
    // `ok:false` is a refusal; `ok:true` with a null name is the ordinary
    // "nobody we know" answer and carries a `reason` we do not read. Both are
    // simply no name — ADR 0008 draws a name only for a confident match.
    if let ok = json["ok"] as? Bool, !ok { return nil }
    if json["error"] != nil { return nil }
    guard let name = json["name"] as? String, !name.isEmpty else { return nil }
    // Re-applied on this side on purpose, though the helper already thresholds:
    // the surface that draws the name is this one, so a helper that started
    // sending tentative scores could never put a guess on screen.
    if let score = json["score"] as? Double, score < matchThreshold { return nil }
    return name
  }

  enum Readiness: Equatable {
    case ready
    /// The helper declined to serve — normally an empty speaker store. The
    /// reason is logged, never shown: there is nothing the owner can do about
    /// it mid-meeting, and a naming notice over a live transcript would be a
    /// second thing narrating one microphone.
    case declined(reason: String?)
  }

  /// The helper's first line. Anything unreadable is a decline — a helper whose
  /// very first line we cannot parse is not one to send a megabyte of somebody's
  /// meeting to.
  static func readiness(fromLine line: Data) -> Readiness {
    guard
      let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
      json["type"] as? String == "ready",
      let ok = json["ok"] as? Bool
    else {
      return .declined(reason: "unreadable readiness line")
    }
    return ok ? .ready : .declined(reason: json["reason"] as? String)
  }

  /// Split a stdout chunk into complete lines plus the unterminated remainder.
  /// Separate from the process so the framing — the part that breaks when a
  /// helper writes two answers in one `write` — is asserted without one.
  static func lines(from buffer: Data) -> (lines: [Data], remainder: Data) {
    var lines: [Data] = []
    var remainder = buffer
    while let index = remainder.firstIndex(of: 0x0A) {
      let raw = Data(remainder[remainder.startIndex..<index])
      remainder = remainder[remainder.index(after: index)...]
      let trimmed = Data(raw.filter { $0 != 0x0D })
      if !trimmed.isEmpty { lines.append(trimmed) }
    }
    return (lines, Data(remainder))
  }

  // MARK: - The child

  private enum Phase {
    case stopped
    case starting
    case ready
    /// Spawn failed, `ready:false`, the child died, or a request went
    /// unanswered. Terminal for the life of this object — a session gets one
    /// helper, and a session that lost it finishes with no more names.
    case declined
  }

  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "voiceprint.helper")
  private let plan: LaunchPlan

  /// Writes go off the main actor, and that is not a nicety. A twelve-second
  /// slice is ~500 KB of base64 against a 64 KB pipe buffer, so a main-actor
  /// `write(contentsOf:)` would block the window — toolbar, meter, transcript —
  /// until the child drained it.
  private let writeQueue = DispatchQueue(label: "com.xiafawu.nota.voiceprint-helper.write")

  /// Writing to a pipe whose reader has gone raises **SIGPIPE**, whose default
  /// action is to kill the process — and a 12 s slice is ~512 KB of base64
  /// against a 64 KB pipe buffer, so the write is genuinely in the kernel for a
  /// while and a helper that dies during it is the ordinary case, not a race
  /// nobody hits. Ignoring the signal turns that into the `EPIPE` the `catch`
  /// below already handles, which is the whole of "a dying helper degrades to
  /// no names, never to a crash". Process-wide and once; every other pipe and
  /// socket in the app wants the same answer.
  private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

  /// `nonisolated(unsafe)` for the reason `FieldEngine.timer` is: `deinit` is
  /// not main-actor isolated and must still be able to kill this child. It is
  /// the last line of defence against a leak — the ordinary way out is `stop()`
  /// closing stdin, and the way out when the app is killed outright is the
  /// helper's own contract to exit on EOF.
  private nonisolated(unsafe) var child: Process?

  private var stdinHandle: FileHandle?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  private var stdoutTail = Data()
  private var didReadReadiness = false

  private var phase: Phase = .stopped
  private var pending: [Int: CheckedContinuation<String?, Never>] = [:]
  private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
  private var nextID = 1

  init(plan: LaunchPlan? = nil) {
    // Touching it is what runs it: a `static let` is lazy, so declaring the
    // signal disposition and never reading it would leave SIGPIPE fatal while
    // reading as though it had been handled.
    _ = Self.ignoreSIGPIPE
    self.plan = plan ?? Self.launchPlan(projectDirectory: Self.projectDirectory)
  }

  deinit {
    child?.terminate()
  }

  var isRunning: Bool { phase == .starting || phase == .ready }

  func start() {
    guard phase == .stopped else { return }
    phase = .starting

    let process = Process()
    process.executableURL = plan.executableURL
    process.arguments = plan.arguments
    process.currentDirectoryURL = plan.currentDirectory

    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors

    output.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      Task { @MainActor in self?.consumeStdout(chunk) }
    }
    errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
      Task { @MainActor in self?.logDiagnostic(text) }
    }
    process.terminationHandler = { [weak self] _ in
      Task { @MainActor in self?.handleTermination() }
    }

    do {
      try process.run()
    } catch {
      // Not an error anybody is told about — a meeting with no names.
      logger.info("live naming unavailable: \(error.localizedDescription, privacy: .public)")
      decline(reason: "spawn failed")
      return
    }

    child = process
    stdinHandle = input.fileHandleForWriting
    stdoutPipe = output
    stderrPipe = errors
    startReadinessTimeout()
    logger.info("voiceprint helper started")
  }

  func identify(_ request: VoiceprintRequest) async -> String? {
    guard isRunning else { return nil }
    guard await waitForReadiness() else { return nil }
    guard phase == .ready, let handle = stdinHandle else { return nil }

    let id = nextID
    nextID += 1
    guard let line = Self.requestLine(id: id, request: request) else { return nil }

    return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      pending[id] = continuation
      writeQueue.async {
        do {
          try handle.write(contentsOf: line)
        } catch {
          // The child is gone or the pipe is closed. `handleTermination` will
          // normally have said so already; this is the case where it has not.
          Task { @MainActor [weak self] in self?.decline(reason: "stdin closed") }
        }
      }
      startTimeout(for: id)
    }
  }

  func stop() {
    let process = child
    child = nil
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    stdoutPipe = nil
    stderrPipe = nil
    process?.terminationHandler = nil

    // Closing stdin is the contract's way out: the helper sees EOF and leaves.
    // `terminate()` is the backstop for one that does not.
    //
    // The close goes through `writeQueue`, the same queue `identify` writes on.
    // Closed from here directly it would race an in-flight write against the
    // very same `FileHandle` — a main-actor close and a background write, no
    // lock — and the loser is either an invalid descriptor or, worse, one the
    // kernel has already handed to something else. Ordering it behind whatever
    // is queued costs nothing: the helper is being torn down either way.
    let closing = stdinHandle
    stdinHandle = nil
    writeQueue.async { try? closing?.close() }
    if process?.isRunning == true { process?.terminate() }

    phase = .stopped
    stdoutTail = Data()
    didReadReadiness = false
    resolveReadiness(false)
    failAllPending()
  }

  // MARK: - Private

  private func consumeStdout(_ chunk: Data) {
    stdoutTail.append(chunk)
    let (lines, remainder) = Self.lines(from: stdoutTail)
    stdoutTail = remainder
    for line in lines {
      if !didReadReadiness {
        didReadReadiness = true
        switch Self.readiness(fromLine: line) {
        case .ready:
          if phase == .starting {
            phase = .ready
            resolveReadiness(true)
          }
        case .declined(let reason):
          decline(reason: reason ?? "helper declined")
        }
        continue
      }
      guard
        let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
        let id = (json["id"] as? String).flatMap(Int.init),
        let continuation = pending.removeValue(forKey: id)
      else { continue }
      continuation.resume(returning: Self.name(fromAnswer: json))
    }
  }

  private func logDiagnostic(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    logger.info("voiceprint helper: \(trimmed.prefix(200), privacy: .public)")
  }

  private func handleTermination() {
    guard phase != .stopped else { return }
    decline(reason: "helper exited")
  }

  /// The one way into "there will be no more names", from every cause. It
  /// leaves the child in place so `stop()` still reaps it, and answers
  /// everything in flight with nil rather than abandoning a turn's
  /// continuation.
  private func decline(reason: String) {
    guard phase != .declined else { return }
    logger.info("live naming off: \(reason, privacy: .public)")
    phase = .declined
    if let process = child, process.isRunning { process.terminate() }
    resolveReadiness(false)
    failAllPending()
  }

  private func waitForReadiness() async -> Bool {
    switch phase {
    case .ready: return true
    case .stopped, .declined: return false
    case .starting:
      return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        readyWaiters.append(continuation)
      }
    }
  }

  private func resolveReadiness(_ value: Bool) {
    let waiters = readyWaiters
    readyWaiters = []
    for waiter in waiters { waiter.resume(returning: value) }
  }

  private func failAllPending() {
    let inFlight = pending
    pending = [:]
    for (_, continuation) in inFlight { continuation.resume(returning: nil) }
  }

  /// A child that starts and then says nothing at all is written off on the
  /// same clock a request is.
  ///
  /// `waitForReadiness` is otherwise unbounded, and the two events that resolve
  /// it — a readiness line, and the child dying — are both things a wedged
  /// process declines to produce. Without this a turn's naming task would wait
  /// for the length of the meeting, and every later turn would queue behind it
  /// on the serial chain.
  private func startReadinessTimeout() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
      guard let self, self.phase == .starting else { return }
      self.decline(reason: "no readiness line in \(Int(Self.requestTimeout))s")
    }
  }

  /// A wedged child must not queue a meeting's worth of turns behind it, so an
  /// unanswered request writes the helper off rather than only itself.
  private func startTimeout(for id: Int) {
    Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
      guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
      continuation.resume(returning: nil)
      self.decline(reason: "no answer in \(Int(Self.requestTimeout))s")
    }
  }
}
