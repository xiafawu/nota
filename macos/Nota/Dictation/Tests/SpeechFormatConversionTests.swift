import AVFoundation
import XCTest

@testable import Nota

/// Regression tests for the SpeechAnalyzer input-format crash: `AnalyzerInput(buffer:)`
/// traps (EXC_BREAKPOINT) when the buffer format differs from
/// `SpeechAnalyzer.bestAvailableAudioFormat` (Int16 on macOS 26), while MicCapture
/// produces Float32. `AppleSpeechStream` must convert before wrapping.
final class SpeechFormatConversionTests: XCTestCase {
  private let float32Mono16k = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16000,
    channels: 1,
    interleaved: false
  )!

  private let int16Mono16k = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16000,
    channels: 1,
    interleaved: true
  )!

  private func makeBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    return buffer
  }

  func testConvertsFloat32ToInt16PreservingFrameCount() {
    let stream = AppleSpeechStream()
    let input = makeBuffer(format: float32Mono16k, frames: 1600)

    let converted = stream.convertBuffer(input, to: int16Mono16k)

    XCTAssertNotNil(converted)
    XCTAssertEqual(converted?.format.commonFormat, .pcmFormatInt16)
    XCTAssertEqual(converted?.format.sampleRate, 16000)
    XCTAssertEqual(converted?.format.channelCount, 1)
    XCTAssertEqual(converted?.frameLength, 1600)
  }

  func testSameFormatPassesThroughWithoutCopy() {
    let stream = AppleSpeechStream()
    let input = makeBuffer(format: int16Mono16k, frames: 320)

    let converted = stream.convertBuffer(input, to: int16Mono16k)

    XCTAssertTrue(converted === input, "identical format should not allocate a new buffer")
  }

  func testConverterReusedAcrossCalls() {
    let stream = AppleSpeechStream()
    for _ in 0..<3 {
      let input = makeBuffer(format: float32Mono16k, frames: 480)
      XCTAssertNotNil(stream.convertBuffer(input, to: int16Mono16k))
    }
  }

  func testEmptyBufferReturnsNilInsteadOfTrapping() {
    let stream = AppleSpeechStream()
    let input = makeBuffer(format: float32Mono16k, frames: 0)

    XCTAssertNil(stream.convertBuffer(input, to: int16Mono16k))
  }
}
