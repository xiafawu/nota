import SwiftUI

// MARK: - CraftTokens

/// Design tokens for the B4 "Craft Glass" home surface (XIA-398).
///
/// Self-contained on purpose: a later home-screen ticket may promote these
/// into `Tokens.swift`; for now everything craft-specific lives here.
enum CraftTokens {
  // MARK: Wash (home ground)

  /// Soft cool color-wash stops — light mode (pale periwinkle → lavender-white).
  static let washLight: [Color] = [
    Color(red: 0.95, green: 0.96, blue: 0.99),
    Color(red: 0.91, green: 0.93, blue: 0.98),
    Color(red: 0.93, green: 0.95, blue: 1.00),
  ]

  /// Deep smoky wash stops — dark mode (charcoal-blue → smoky indigo).
  static let washDark: [Color] = [
    Color(red: 0.12, green: 0.13, blue: 0.18),
    Color(red: 0.10, green: 0.11, blue: 0.16),
    Color(red: 0.14, green: 0.13, blue: 0.19),
  ]

  /// The home ground gradient, adapting to the current color scheme.
  static func washGradient(_ scheme: ColorScheme) -> LinearGradient {
    LinearGradient(
      colors: scheme == .dark ? washDark : washLight,
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  /// Whisper of film grain on top of the wash (opacity per scheme; the grain
  /// color is inverted per scheme so it reads on either ground).
  static func noiseOpacity(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.045 : 0.025 }
  static func noiseColor(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white : .black }

  // MARK: Glass panel (hairline + shadow)

  /// Hairline border: `primary` adapts automatically to light/dark grounds.
  static let hairline: Color = Color.primary.opacity(0.10)
  static let panelHairlineWidth: CGFloat = 1

  static let panelShadowRadius: CGFloat = 12
  static let panelShadowY: CGFloat = 4
  static func panelShadowColor(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.black.opacity(0.30) : Color.black.opacity(0.08)
  }

  // MARK: Primary card (confident blue)

  /// Strong saturated blue; white foreground on it holds ~4.6:1 contrast
  /// (WCAG AA for normal text) — deliberately a touch deeper than systemBlue.
  static let primaryBlue: Color = Color(red: 0.13, green: 0.42, blue: 0.98)
  static let primaryForeground: Color = .white

  /// Colored (blue) shadow for the confident lift of the primary card.
  static let primaryShadowRadius: CGFloat = 16
  static let primaryShadowY: CGFloat = 8
  static func primaryShadowColor(_ scheme: ColorScheme) -> Color {
    primaryBlue.opacity(scheme == .dark ? 0.45 : 0.32)
  }

  // MARK: Chips (flat soft tint)

  static let chipCornerRadius: CGFloat = 6
  static let chipFont: Font = .system(size: 11, weight: .medium)
  /// Craft-docs style chip padding (per B4: "h6 v3").
  static let chipPaddingH: CGFloat = 6
  static let chipPaddingV: CGFloat = 3

  // MARK: Dashed drop-target card

  static let dropDashWidth: CGFloat = 1.5
  static let dropDashPattern: [CGFloat] = [6, 6]
  static let dropStrokeColor: Color = Color.primary.opacity(0.30)

  // MARK: Type

  /// Serif appears exactly once on the home surface: the greeting, with the
  /// name in italic (Iowan Old Style / New York via `.system(design: .serif)`).
  static let greetingFont: Font = .system(size: 34, weight: .regular, design: .serif)
  /// Mono for metadata (timestamps).
  static let metadataFont: Font = .system(size: 12, weight: .regular, design: .monospaced)
  /// Mono for keyboard shortcuts.
  static let shortcutFont: Font = .system(size: 12, weight: .medium, design: .monospaced)

  // MARK: 8pt grid

  static let spacing4: CGFloat = 4
  static let spacing8: CGFloat = 8
  static let spacing12: CGFloat = 12
  static let spacing16: CGFloat = 16
  static let spacing24: CGFloat = 24
  static let spacing32: CGFloat = 32
}

// MARK: - Chip tint

/// Flat soft-tint variants for `SoftTintChip` (Craft-docs style: no glazed
/// jewel chips, no teal active-edge bracket).
enum CraftChipTint {
  case red
  case gold
  case green

  /// Stronger shade of the tint, used for the label.
  var foreground: Color {
    switch self {
    case .red:   return Color(red: 0.78, green: 0.25, blue: 0.28)
    case .gold:  return Color(red: 0.78, green: 0.57, blue: 0.12)
    case .green: return Color(red: 0.19, green: 0.57, blue: 0.33)
    }
  }

  /// Tint at low opacity — the flat soft background.
  var fill: Color { foreground.opacity(0.13) }
}

// MARK: - Deterministic noise

/// Tiny SplitMix64 so the grain pattern is stable across redraws (no
/// shimmering in previews or live views).
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// The "whisper of noise" layer: a seeded grid of tiny dots at very low
/// opacity. Static (deterministic seed) so it never flickers.
private struct CraftNoiseLayer: View {
  let opacity: Double
  let color: Color
  private let seed: UInt64

  init(opacity: Double, color: Color, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
    self.opacity = opacity
    self.color = color
    self.seed = seed
  }

  var body: some View {
    Canvas { context, size in
      var rng = SplitMix64(seed: seed)
      let columns = 28
      let rows = max(1, Int(size.height / size.width * CGFloat(columns)))
      let cellW = size.width / CGFloat(columns)
      let cellH = size.height / CGFloat(rows)
      context.opacity = opacity
      for row in 0..<rows {
        for col in 0..<columns {
          let jitterX = CGFloat(rng.next() >> 8) / CGFloat(1 << 24) * cellW
          let jitterY = CGFloat(rng.next() >> 8) / CGFloat(1 << 24) * cellH
          let radius = 0.4 + CGFloat(rng.next() >> 8) / CGFloat(1 << 24) * 0.6
          let rect = CGRect(
            x: CGFloat(col) * cellW + jitterX,
            y: CGFloat(row) * cellH + jitterY,
            width: radius,
            height: radius
          )
          context.fill(Path(ellipseIn: rect), with: .color(color))
        }
      }
    }
    .allowsHitTesting(false)
  }
}

// MARK: - Home ground

/// The B4 home ground: cool color-wash gradient + whisper of noise, adapting
/// to the color scheme. Fills the view it's placed in (and extends under the
/// titlebar, which is part of the home surface).
struct CraftWashBackground: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    CraftTokens.washGradient(colorScheme)
      .overlay(
        CraftNoiseLayer(
          opacity: CraftTokens.noiseOpacity(colorScheme),
          color: CraftTokens.noiseColor(colorScheme)
        )
      )
      .ignoresSafeArea()
  }
}

// MARK: - Glass panel

private struct CraftGlassPanelModifier<S: Shape>: ViewModifier {
  let shape: S
  let tint: Color
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    let glass: Glass = tint == .clear ? .regular : .regular.tint(tint)
    content
      .liquidGlass(glass, in: shape)
      // Hairline sits on the same .continuous outline as the glass, drawn
      // centered on the path (1pt hairline: the 0.5pt outward half is
      // imperceptible and keeps `S: Shape` call sites unconstrained).
      .overlay(shape.stroke(CraftTokens.hairline, lineWidth: CraftTokens.panelHairlineWidth))
      .shadow(
        color: CraftTokens.panelShadowColor(colorScheme),
        radius: CraftTokens.panelShadowRadius,
        x: 0,
        y: CraftTokens.panelShadowY
      )
  }
}

extension View {
  /// Frosted glass panel: `.regularMaterial` (or `.regular` glassEffect)
  /// + hairline border + gentle shadow. Reduce Transparency degrades via the
  /// existing `liquidGlass` branch (system materials), hairline and shadow
  /// stay. `tint` opts into a tinted glass (pass `.clear` for plain).
  func craftGlassPanel<S: Shape>(in shape: S, tint: Color = .clear) -> some View {
    modifier(CraftGlassPanelModifier(shape: shape, tint: tint))
  }
}

// MARK: - Soft tint chip

/// Flat soft-tint rounded square (Craft-docs style) with a label. Informational
/// by nature — wrap with a larger hit area if it ever becomes a control
/// (44pt target rule applies to interactive targets only).
struct SoftTintChip: View {
  let text: String
  var tint: CraftChipTint = .red

  var body: some View {
    Text(text)
      .font(CraftTokens.chipFont)
      .foregroundStyle(tint.foreground)
      .padding(.horizontal, CraftTokens.chipPaddingH)
      .padding(.vertical, CraftTokens.chipPaddingV)
      .background(
        tint.fill,
        in: RoundedRectangle(cornerRadius: CraftTokens.chipCornerRadius, style: .continuous)
      )
  }
}

// MARK: - Primary card

private struct CraftPrimaryCardModifier<S: Shape>: ViewModifier {
  let shape: S
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .foregroundStyle(CraftTokens.primaryForeground)
      .background(CraftTokens.primaryBlue, in: shape)
      .shadow(
        color: CraftTokens.primaryShadowColor(colorScheme),
        radius: CraftTokens.primaryShadowRadius,
        x: 0,
        y: CraftTokens.primaryShadowY
      )
  }
}

extension View {
  /// Confident blue solid card with a colored (blue) shadow. Solid fill means
  /// it reads the same under Reduce Transparency — no material branch needed.
  func craftPrimaryCard<S: Shape>(in shape: S) -> some View {
    modifier(CraftPrimaryCardModifier(shape: shape))
  }
}

// MARK: - Dashed drop-target card

private struct CraftDashedDropCardModifier<S: Shape>: ViewModifier {
  let shape: S

  func body(content: Content) -> some View {
    content
      .background(.thinMaterial, in: shape)
      .overlay(
        shape.stroke(
          CraftTokens.dropStrokeColor,
          style: StrokeStyle(
            lineWidth: CraftTokens.dropDashWidth,
            dash: CraftTokens.dropDashPattern
          )
        )
      )
  }
}

extension View {
  /// Dashed-border drop-target card: thin material fill + dashed stroke.
  /// `.thinMaterial` degrades automatically under Reduce Transparency.
  func craftDashedDropCard<S: Shape>(in shape: S) -> some View {
    modifier(CraftDashedDropCardModifier(shape: shape))
  }
}

// MARK: - Greeting

/// The one serif on the home surface: a greeting with the name in italic.
/// Time-of-day prefix is a caller concern (wired by a later ticket); the
/// default matches the B4 reference copy.
struct CraftGreeting: View {
  let name: String
  var prefix: String = "Good evening, "

  var body: some View {
    (Text(prefix) + Text(name).italic())
      .font(CraftTokens.greetingFont)
      .foregroundStyle(.primary)
  }
}

// MARK: - Previews

#if DEBUG
#Preview("wash – light") {
  CraftWashBackground()
    .frame(width: 640, height: 420)
    .preferredColorScheme(.light)
}

#Preview("wash – dark") {
  CraftWashBackground()
    .frame(width: 640, height: 420)
    .preferredColorScheme(.dark)
}

#Preview("glass panel – light") {
  CraftWashBackground()
    .overlay(
      HStack(spacing: CraftTokens.spacing16) {
        Text("Plain glass")
          .padding(CraftTokens.spacing16)
          .craftGlassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        Text("Tinted glass")
          .padding(CraftTokens.spacing16)
          .craftGlassPanel(
            in: RoundedRectangle(cornerRadius: 16, style: .continuous),
            tint: .accentColor
          )
      }
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.light)
}

#Preview("glass panel – dark") {
  CraftWashBackground()
    .overlay(
      Text("Plain glass")
        .padding(CraftTokens.spacing16)
        .craftGlassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.dark)
}

#Preview("chips – light") {
  CraftWashBackground()
    .overlay(
      HStack(spacing: CraftTokens.spacing8) {
        SoftTintChip(text: "Todo", tint: .red)
        SoftTintChip(text: "Idea", tint: .gold)
        SoftTintChip(text: "Done", tint: .green)
      }
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.light)
}

#Preview("chips – dark") {
  CraftWashBackground()
    .overlay(
      HStack(spacing: CraftTokens.spacing8) {
        SoftTintChip(text: "Todo", tint: .red)
        SoftTintChip(text: "Idea", tint: .gold)
        SoftTintChip(text: "Done", tint: .green)
      }
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.dark)
}

#Preview("primary card – light") {
  CraftWashBackground()
    .overlay(
      Text("New Note")
        .font(.headline)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .craftPrimaryCard(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.light)
}

#Preview("primary card – dark") {
  CraftWashBackground()
    .overlay(
      Text("New Note")
        .font(.headline)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .craftPrimaryCard(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.dark)
}

#Preview("dashed drop card") {
  CraftWashBackground()
    .overlay(
      VStack(spacing: CraftTokens.spacing8) {
        Text("Drop files here")
          .font(.callout)
          .foregroundStyle(.secondary)
        Text("⌘N").font(CraftTokens.shortcutFont)
      }
      .frame(width: 260, height: 140)
      .craftDashedDropCard(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.light)
}

#Preview("dashed drop card – dark") {
  CraftWashBackground()
    .overlay(
      Text("Drop files here")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(width: 260, height: 140)
        .craftDashedDropCard(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(CraftTokens.spacing32)
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.dark)
}

#Preview("greeting – light") {
  CraftWashBackground()
    .overlay(
      CraftGreeting(name: "Amara")
        .padding(CraftTokens.spacing32),
      alignment: .topLeading
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.light)
}

#Preview("greeting – dark") {
  CraftWashBackground()
    .overlay(
      CraftGreeting(name: "Amara")
        .padding(CraftTokens.spacing32),
      alignment: .topLeading
    )
    .frame(width: 640, height: 420)
    .preferredColorScheme(.dark)
}
#endif
