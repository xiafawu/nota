import SwiftUI

/// The ground, drawn.
///
/// A drop-in replacement for `CraftWashBackground` at the surfaces that carry
/// the app's ground — the home dashboard, the live session and the document.
/// **The two light reading states wear paper instead** (`GroundPaper`, ADR
/// 0007) — the live session and the document, tinted from the same palette so
/// nothing changes at Stop. Everything below is about the field, which home
/// draws in both themes and every role draws in dark. It keeps that view's
/// whole contract: it fills whatever it is put in, it extends under the
/// titlebar, and it takes no clicks.
///
/// It is a **64×36 image scaled to a window**, which is not a compromise: every
/// feature in the field is a soft blob hundreds of points across, so the
/// upscale is the blur, and interpolation is what turns 2,304 cells into
/// something continuous. `.high` is load-bearing — at `.none` or `.low` the
/// same buffer reads as a grid of squares, which is the failure this whole
/// approach looks like when it is done wrong.
///
/// **The layering is three flat siblings, and that is the whole performance
/// story.** Only `FieldImageLayer` holds the `@ObservedObject`, so a published
/// frame re-evaluates *its* body and nothing else. The first cut put the
/// observation on this struct and hung the grain off it as an `.overlay`, which
/// meant `CraftNoiseLayer` — a `Canvas` whose renderer closure is not
/// comparable, so SwiftUI re-runs it whenever the body it lives in is
/// re-evaluated — redrew roughly 476 ellipses across the full window twenty
/// times a second, on the same main actor as the hotkey tap and the recording
/// pane. It had previously run **once, ever**, because `CraftWashBackground`'s
/// body never changed. This is `SessionMeterFeedView`'s shape and it is here for
/// the same reason: the *rate* of a publisher and the *breadth* of its
/// observers multiply, and the fix is always to narrow the observer rather than
/// to slow the publisher.
///
/// **The floor is the wash GRADIENT, not `CraftWashBackground`.** That view is
/// the gradient *plus its own* `CraftNoiseLayer`, so putting it here drew the
/// grain twice — two full-window `Canvas` passes, ~952 seeded ellipse fills at
/// 1280×800, on every body evaluation and every resize, with the lower pair
/// permanently occluded by the opaque field image. Exactly one of them could
/// ever be seen and both were always drawn, which is the second answer to what
/// the app's ground is made of that `CraftNoiseLayer`'s own note forbids. What
/// the floor is *for* is the paragraph below, and a `LinearGradient` is all of
/// it: the grain belongs on top of the field, not under it.
///
/// **The wash is underneath, always — it is not an `if`/`else`.** A branch meant
/// the first body evaluation drew the cool periwinkle wash (`engine.image` is
/// nil until `onAppear` runs, and `onAppear` runs *after* the evaluation that
/// installed it), and the first frame then swapped the subtree outright: a hard
/// cut from blue to whichever of the sixteen grounds the launch drew, with no
/// crossfade because a `_ConditionalContent` branch change is not an animation.
/// Keeping the wash as the floor makes the arrival a fade over it, makes the
/// CoreGraphics-refusal case degrade to the surface that was there before
/// rather than to a hole, and costs one static gradient that never re-evaluates.
///
/// **The grain stays** because without it a smooth gradient bands on a real
/// display — 8-bit steps across a full-window ramp are visible, and the eye
/// reads the contours as a synthetic surface rather than as light.
///
/// No `.drawingGroup()`: it would rasterize the ground into an offscreen buffer
/// on every published frame, which is the opposite of what a single scaled
/// image needs.
struct FieldBackground: View {
  /// A plain `let`, deliberately **not** an `@ObservedObject`. This struct must
  /// not re-evaluate when a frame is published; it holds the engine only to
  /// push the environment into it and to keep the viewer count.
  private let engine: FieldEngine

  /// Which of the launch family's three grounds this surface wears.
  ///
  /// Declared by the call site rather than inferred from anything, because
  /// "which view am I" is not a question the ground can answer — the same
  /// `MainPaneView` hosts a transcript and a processing run, and both are the
  /// same role for a different reason than they are the same view.
  private let role: GroundRole

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Defaults to the shared engine so the two call sites share one ground; the
  /// parameter exists so a preview or a test can drive its own.
  init(role: GroundRole, engine: FieldEngine = .shared) {
    self.role = role
    self.engine = engine
  }

  /// Whether this surface is currently counted as a viewer of the engine.
  /// A paper surface is not one — see `wearsPaper`.
  @State private var isViewing = false

  /// The light reading states — the live session and the document — wear flat
  /// paper instead of the field (`GroundPaper`). It is decided from two things
  /// this view already reads, so a colour scheme that flips while either is up
  /// moves the surface between paper and field without anyone asking the
  /// engine to.
  private var wearsPaper: Bool {
    GroundPaper.wears(role: role, light: colorScheme == .light)
  }

  var body: some View {
    ZStack {
      CraftTokens.washGradient(colorScheme)
      if wearsPaper {
        // The family, not the role: `GroundPaper` tints every paper surface
        // from the transcript's palette, so the live session and the document
        // are the same colour and Stop changes nothing (ADR 0007). And the
        // family rather than `engine.palette`, because the engine may be
        // sitting on home's ground — a paper surface never asks it to move.
        GroundPaper.swiftUIColor(in: engine.family)
      } else {
        FieldImageLayer(engine: engine)
      }
      CraftNoiseLayer(
        opacity: CraftTokens.noiseOpacity(colorScheme),
        color: CraftTokens.noiseColor(colorScheme)
      )
    }
    .allowsHitTesting(false)
    .ignoresSafeArea()
    // Both settings are pushed in rather than read by the engine, which has no
    // environment of its own — it outlives every view that draws it. And both
    // are pushed on appearance *and* on change: a colour scheme that flips
    // while the view is up is the ordinary case (Settings → General, or the
    // system at sunset), and an engine that only learned it once would hold a
    // light band under a dark app.
    .onAppear {
      engine.light = (colorScheme == .light)
      engine.reduceMotion = reduceMotion
      reconcileViewer()
    }
    .onDisappear {
      if isViewing {
        engine.removeViewer()
        isViewing = false
      }
    }
    .onChange(of: colorScheme) { _, new in
      engine.light = (new == .light)
      reconcileViewer()
    }
    .onChange(of: reduceMotion) { _, new in engine.reduceMotion = new }
    .onChange(of: role) { _, _ in reconcileViewer() }
  }

  /// A field surface holds a viewer and steers the engine's role; a paper
  /// surface does neither — the engine's clock has nobody to draw for, and a
  /// ground nobody drew must not become the target the *home* screen morphs
  /// back from. With two roles wearing paper in light, a whole light-mode
  /// session (record, stop, read) can pass without the engine running at all,
  /// and home still morphs back from home's own ground.
  ///
  /// The role is set before `addViewer`, which paints if there is no frame
  /// yet: a first frame painted at the previous role's ground would be a cut
  /// that the morph then has to walk back.
  ///
  /// Two surfaces are briefly mounted at once while ContentView cross-fades
  /// its phases, so the last one to reconcile wins — which is the incoming
  /// view, and therefore right. Nothing clears the role on the way out for the
  /// same reason: the outgoing view must not drag the ground back with it.
  private func reconcileViewer() {
    if wearsPaper {
      if isViewing {
        engine.removeViewer()
        isViewing = false
      }
    } else {
      engine.role = role
      if !isViewing {
        engine.addViewer()
        isViewing = true
      }
    }
  }
}

/// The one view in the app that observes `FieldEngine`.
///
/// Split out of `FieldBackground` so that a published frame invalidates exactly
/// this — an `Image` in a `GeometryReader` — and not the grain, the wash, or
/// anything an ancestor happens to be holding. See `FieldBackground`'s note.
///
/// It draws nothing at all until the first frame exists, which is safe because
/// the wash is already underneath it; the fade is what makes the arrival read
/// as the ground resolving rather than as a surface being replaced.
private struct FieldImageLayer: View {
  @ObservedObject var engine: FieldEngine

  var body: some View {
    GeometryReader { proxy in
      if let image = engine.image {
        Image(decorative: image, scale: 1, orientation: .up)
          .resizable()
          .interpolation(.high)
          .scaledToFill()
          .frame(width: proxy.size.width, height: proxy.size.height)
          .clipped()
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: FieldBackgroundMetrics.arrivalFade), value: engine.image != nil)
  }
}

/// The view's two numbers, kept out of the view for the reason
/// `SessionTimerMetrics` and `HUDPillMetrics` are: they are then assertable
/// without a hosting view.
enum FieldBackgroundMetrics {
  /// How long the field takes to fade up over the wash on the first frame.
  ///
  /// Long enough to read as a resolve rather than a cut, short enough that
  /// nobody waiting for the window to finish opening notices it. It runs once
  /// per launch — `engine.image` goes non-nil and stays that way.
  static let arrivalFade: TimeInterval = 0.45
}

#if DEBUG
#Preview("Field ground") {
  ZStack {
    FieldBackground(role: .home)
    Text("Good afternoon")
      .font(.system(size: 34, weight: .semibold))
  }
  .frame(width: 780, height: 520)
}
#endif
