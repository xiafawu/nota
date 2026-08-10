import Foundation

/// The current the field flows on.
///
/// Velocity is the perpendicular gradient of a smooth scalar potential, which
/// makes it **divergence-free by construction** — the flow can stir the field
/// indefinitely without ever accumulating or draining colour at a point. That
/// is the property that makes this read as water rather than as a crossfade;
/// a hand-authored velocity field almost always has sources and sinks in it,
/// and they show up as colour piling into a corner over a long session.
///
/// Three octaves: one that carries the whole frame, one that folds it, one that
/// puts a grain on the fold. Amplitudes fall off faster than the frequencies
/// rise, so the large motion dominates and the small ones are texture.
///
/// Pure arithmetic on `(u, v, t)` — no state, no allocation, no ownership. It
/// is called once per cell per frame plus once per seed, so it is the hottest
/// thing in the engine and it is also the easiest thing in the engine to assert
/// about without a window server.
enum CurlFlow {
  struct Octave: Sendable {
    /// Spatial frequency across u.
    let k: Double
    /// Spatial frequency across v.
    let l: Double
    /// Angular speed — how fast this octave's pattern travels.
    let w: Double
    /// Amplitude.
    let a: Double
    /// Phase offset, so the octaves do not all peak on the same beat.
    let p: Double
  }

  static let octaves: [Octave] = [
    Octave(k: 2.1, l: 1.7, w: 0.17, a: 1.00, p: 0.0),
    Octave(k: 3.7, l: 3.1, w: 0.24, a: 0.46, p: 1.9),
    Octave(k: 6.3, l: 5.2, w: 0.33, a: 0.20, p: 3.4),
  ]

  /// Overall speed. Small on purpose — at 0.030 a feature crosses the frame in
  /// well over a minute, which is the difference between ambient and a
  /// screensaver.
  static let speed: Double = 0.030

  /// Velocity at a point, in normalised units per second.
  ///
  /// - Parameters:
  ///   - u: horizontal position, 0...1.
  ///   - v: vertical position, 0...1.
  ///   - t: elapsed seconds.
  static func velocity(u: Double, v: Double, t: Double) -> (vx: Double, vy: Double) {
    var vx = 0.0
    var vy = 0.0
    for o in octaves {
      let s1 = sin(o.k * u + o.w * t + o.p)
      let c1 = cos(o.k * u + o.w * t + o.p)
      let s2 = sin(o.l * v - o.w * t)
      let c2 = cos(o.l * v - o.w * t)
      vx += o.a * s1 * (-o.l * s2)
      vy += -o.a * (o.k * c1) * c2
    }
    return (vx * speed, vy * speed)
  }
}
