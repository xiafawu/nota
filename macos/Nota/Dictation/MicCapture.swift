import AVFoundation
import Foundation
import os

final class MicCapture: ObservableObject {
  @Published private(set) var diagnostics: CaptureDiagnostics?
  @Published private(set) var rmsLevel: Float = 0

  /// Map a raw RMS sample to a 0…1 meter level.
  ///
  /// Perceptual dB transfer (`20·log10`, −50 dB floor, normalized) instead of
  /// a linear scale: conversational speech (RMS ~0.05–0.2) lands mid-meter
  /// and whispers still register. A fast-attack / slow-release envelope
  /// against the previous level makes peaks hit instantly and decay smoothly.
  static func meterLevel(rms: Float, previous: Float) -> Float {
    let floorDB: Float = -50
    let db = 20 * log10(max(rms, .leastNormalMagnitude))
    let normalized = min(max((db - floorDB) / -floorDB, 0), 1)
    let attack: Float = 0.7
    let release: Float = 0.15
    let alpha = normalized > previous ? attack : release
    return previous + alpha * (normalized - previous)
  }
  var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

  private let audioEngine = AVAudioEngine()
  private let stateLock = OSAllocatedUnfairLock(initialState: false)
  /// Converted buffers waiting for the main thread to hand them on.
  ///
  /// The tap runs on the audio IO thread and delivery has to reach the
  /// recognizer from the main actor, so every buffer crosses a queue hop. What
  /// is in flight across that hop when `stop()` runs is the last audio of the
  /// session — the words spoken just before the release — and it used to be
  /// discarded by an `isCapturing` check that had already flipped. Holding the
  /// buffers here lets `stop()` drain them synchronously, before the analyzer
  /// is told the input ended.
  private let pending = PendingPCMBuffers()
  private let logger = Logger(subsystem: "com.xiafawu.nota", category: "dictation.capture")

  var isCapturing: Bool {
    stateLock.withLock { $0 }
  }

  func start() throws {
    guard !isCapturing else { return }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw MicCaptureError.permissionDenied
    }

    let inputNode = audioEngine.inputNode
    let sourceFormat = inputNode.inputFormat(forBus: 0)
    guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
      throw MicCaptureError.noInputDevice
    }

    let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 16_000,
      channels: 1,
      interleaved: false
    )
    guard let targetFormat else {
      throw MicCaptureError.invalidInputFormat
    }
    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
      throw MicCaptureError.converterUnavailable
    }

    let sessionID = UUID()
    // Anything the previous session's tap appended after its final drain
    // belongs to nobody: drop it here rather than feed it to this session.
    _ = pending.take()
    stateLock.withLock { $0 = true }
    diagnostics = CaptureDiagnostics(
      sessionID: sessionID,
      startedAt: Date(),
      stoppedAt: nil,
      bufferCount: 0,
      sampleCount: 0,
      lastBufferAt: nil
    )

    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: sourceFormat) {
      [weak self, converter] buffer, _ in
      self?.convertAndRecord(buffer, using: converter, sourceFormat: sourceFormat)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
      logger.info("capture session started: \(sessionID.uuidString, privacy: .public)")
    } catch {
      inputNode.removeTap(onBus: 0)
      stateLock.withLock { $0 = false }
      diagnostics = nil
      throw MicCaptureError.engineStartFailed(error.localizedDescription)
    }
  }

  func stop() {
    guard isCapturing else { return }
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()

    // Drain BEFORE clearing the flag and before the caller finalizes the
    // recognizer: these buffers are the tail of the session, already captured
    // and converted, and the queue hop is the only reason they had not been
    // handed on yet. `stop()` is called from the main actor, so this is the
    // same thread the queued drain would have used.
    drainPending()

    stateLock.withLock { $0 = false }

    guard var diagnostics else { return }
    diagnostics.stoppedAt = Date()
    self.diagnostics = diagnostics
    logger.info(
      "capture session stopped: \(diagnostics.sessionID.uuidString, privacy: .public), buffers=\(diagnostics.bufferCount), samples=\(diagnostics.sampleCount)"
    )
  }

  private func convertAndRecord(
    _ sourceBuffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    sourceFormat: AVAudioFormat
  ) {
    guard isCapturing else { return }

    let ratio = 16_000 / sourceFormat.sampleRate
    let frameCapacity = AVAudioFrameCount(
      max(1, Int(ceil(Double(sourceBuffer.frameLength) * ratio)) + 1)
    )
    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
      )!,
      frameCapacity: frameCapacity
    ) else {
      return
    }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) {
      _, inputStatus in
      guard !suppliedInput else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      suppliedInput = true
      inputStatus.pointee = .haveData
      return sourceBuffer
    }

    guard status == .haveData || status == .inputRanDry,
          outputBuffer.frameLength > 0,
          conversionError == nil else {
      if let conversionError {
        logger.error("PCM conversion failed: \(conversionError.localizedDescription, privacy: .public)")
      }
      return
    }
    pending.append(outputBuffer)
    DispatchQueue.main.async { [weak self] in
      self?.drainPending()
    }
  }

  /// Hand every buffer captured so far to the recognizer, on the main thread.
  ///
  /// Deliberately not gated on `isCapturing`: this audio was recorded while the
  /// session was live, and dropping it because the flag flipped in between is
  /// exactly how the last words of a session went missing. `stop()` drains
  /// before it clears the flag, and `start()` clears the queue, so nothing here
  /// can leak into another session.
  private func drainPending() {
    let buffers = pending.take()
    guard !buffers.isEmpty else { return }
    // Diagnostics are bookkeeping: their absence must never cost audio.
    var diagnostics = self.diagnostics

    for outputBuffer in buffers {
      diagnostics?.bufferCount += 1
      diagnostics?.sampleCount += Int(outputBuffer.frameLength)
      diagnostics?.lastBufferAt = Date()

      // Compute RMS level from the converted PCM buffer
      if let channelData = outputBuffer.floatChannelData {
        let samples = UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength))
        var sumSq: Float = 0
        for i in 0..<samples.count {
          let s = samples[i]
          sumSq += s * s
        }
        let rms = sqrt(sumSq / Float(samples.count))
        self.rmsLevel = Self.meterLevel(rms: rms, previous: self.rmsLevel)
      }

      onPCMBuffer?(outputBuffer)
      logger.debug(
        "PCM buffer #\(diagnostics?.bufferCount ?? 0) frames=\(outputBuffer.frameLength) sampleRate=16000 channels=1"
      )
    }
    if let diagnostics { self.diagnostics = diagnostics }
  }
}

// MARK: - PendingPCMBuffers

/// A FIFO handoff from the audio IO thread to the main thread.
///
/// `AVAudioPCMBuffer` is not `Sendable`, and the ownership rule that makes this
/// safe is the one the class enforces: a buffer is produced by the tap, handed
/// over here, and then only ever read by the single consumer that takes it.
/// `take()` empties the queue, so no two consumers can see the same buffer.
final class PendingPCMBuffers: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [AVAudioPCMBuffer] = []

  init() {}

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    items.append(buffer)
    lock.unlock()
  }

  /// Every buffer appended since the last take, in capture order.
  func take() -> [AVAudioPCMBuffer] {
    lock.lock()
    let taken = items
    items = []
    lock.unlock()
    return taken
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return items.count
  }
}
