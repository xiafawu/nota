import AVFoundation
import Foundation
import os

final class MicCapture: ObservableObject {
  @Published private(set) var diagnostics: CaptureDiagnostics?
  var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

  private let audioEngine = AVAudioEngine()
  private let stateLock = OSAllocatedUnfairLock(initialState: false)
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

    DispatchQueue.main.async { [weak self] in
      guard let self, self.isCapturing else { return }
      guard var diagnostics = self.diagnostics else { return }
      diagnostics.bufferCount += 1
      diagnostics.sampleCount += Int(outputBuffer.frameLength)
      diagnostics.lastBufferAt = Date()
      self.diagnostics = diagnostics
      self.onPCMBuffer?(outputBuffer)
      self.logger.debug(
        "PCM buffer #\(diagnostics.bufferCount) frames=\(outputBuffer.frameLength) sampleRate=16000 channels=1"
      )
    }
  }
}
