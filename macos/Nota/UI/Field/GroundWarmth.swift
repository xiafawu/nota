import Foundation

/// The ground warms as the session runs.
///
/// **Asymptotic**, settled by the owner 2026-08-09: `warmth(t) = 1 - exp(-t/540)`,
/// a nine-minute time constant. Linear and stepped were measured against it and
/// were never a real choice — mean CIE76 ΔE between them ran 0.1–6.3, mostly
/// under the 2.3 just-noticeable threshold, so the decision was asymptotic or
/// nothing.
///
/// Three properties it owes, and each one is a rule rather than a side effect:
///
/// - **Monotonic**, and a function of elapsed time *alone*. Not of speech, not
///   of the level, not of how many people are talking. A ground that responded
///   to the room would be a second indicator competing with the meter.
/// - **Never resets mid-session.** There is no phase, no cycle, no return.
/// - **It never reaches ember.** Ember (`#d1662a` / `#e8823a`) means the
///   microphone is open and nothing else may draw with it. Warming rotates hues
///   toward a 40° anchor at low saturation; ember is 22–25° at 80% saturation.
///   The separation that actually holds is **saturation**, not hue — the ground
///   tops out near 38% (light) / 50% (dark) and cannot get near 80% — which is
///   worth saying plainly, because `kiln` has a base hue of 30° and sits inside
///   the ember hue band from the first frame at warmth zero. See
///   `testTheGroundNeverComesNearEmber`, which measures the distance in Lab
///   rather than asserting a hue window that was never true.
enum GroundWarmth {
  /// Seconds. Nine minutes: at ten minutes the ground is ~67% warmed, at half
  /// an hour ~97%.
  static let timeConstant: Double = 540

  /// Degrees. Warm, and deliberately clear of ember on the far side of it.
  static let anchorHue: Double = 40

  /// How far a *seed* hue is pulled toward the anchor at full warmth.
  static let seedHuePull: Double = 0.62

  /// How far the *base wash* is pulled — about half the seeds' rate. The field
  /// warms; the wall behind it barely does.
  ///
  /// This is **0.33**, from the reference implementation
  /// (`.claude/design-2026-08-09/warmcurve.html`, `towardWarm(p.base, w*.33)`).
  /// The plan file said 21%; the prototype is the spec and the plan was wrong.
  static let baseHuePull: Double = 0.33

  /// Saturation lifts a little with warmth as well, so the warming is not a
  /// pure hue rotation at fixed chroma (which reads as a colour-cast filter).
  static let baseSaturationLift: Double = 0.03
  static let seedSaturationLift: Double = 0.10

  /// 0 at t=0, asymptotically 1. Never exceeds 1, never decreases.
  static func warmth(elapsed: TimeInterval) -> Double {
    guard elapsed > 0 else { return 0 }
    return 1 - exp(-elapsed / timeConstant)
  }

  /// Rotate a hue toward the warm anchor **the short way round**.
  ///
  /// Load-bearing: a hue that travels the long arc crosses the far side of the
  /// wheel, and every intermediate on the way is mud. Blue-violet reaching warm
  /// through green is the exact failure the `soft-field` invariants call out.
  ///
  /// - Parameter amount: 0 leaves the hue alone, 1 lands it on the anchor.
  static func rotate(hue: Double, amount: Double) -> Double {
    var delta = anchorHue - hue
    if delta > 180 { delta -= 360 }
    if delta < -180 { delta += 360 }
    return hue + delta * amount
  }
}
