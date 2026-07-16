import AVFoundation
import Foundation

// MARK: - Hypothesis

struct Hypothesis: Equatable, Sendable {
  let text: String
  let isFinal: Bool
}

// MARK: - SpeechStream protocol

protocol SpeechStream: AnyObject {
  var hypotheses: AsyncStream<Hypothesis> { get }
  func start() async throws
  func feed(_ pcm: AVAudioPCMBuffer) throws
  func finish() async throws -> String
  func cancel()
}
