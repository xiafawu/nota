import CoreGraphics
import Foundation

/// Turns the simulation's `[Float]` buffer into something drawable.
///
/// Kept apart from `FieldSimulation` on purpose: the simulation is pure
/// arithmetic with no CoreGraphics in it at all, so every invariant about the
/// field is assertable without a window server, a colour space, or a main
/// actor. This file is the one place that crosses over.
///
/// It is also cheap enough not to matter — about 1 µs at 64×36, against 115 µs
/// for the step that produced the buffer.
enum FieldImage {
  static let colorSpace = CGColorSpaceCreateDeviceRGB()

  /// Row-major RGBA8, opaque. Returns nil only if the buffer is the wrong size
  /// or CoreGraphics refuses the provider.
  static func makeImage(from buffer: [Float], width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, buffer.count == width * height * 3 else { return nil }

    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    var src = 0
    var dst = 0
    while src < buffer.count {
      for k in 0..<3 {
        let v = buffer[src + k]
        bytes[dst + k] = UInt8(v < 0 ? 0 : (v > 255 ? 255 : v.rounded()))
      }
      src += 3
      dst += 4
    }

    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent)
  }

  static func makeImage(from simulation: FieldSimulation) -> CGImage? {
    makeImage(from: simulation.buffer, width: simulation.width, height: simulation.height)
  }
}
