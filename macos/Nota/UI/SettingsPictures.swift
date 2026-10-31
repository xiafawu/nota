import SwiftUI

/// **Settings with pictures** (owner, 2026-10-30: "copy what Apple does in
/// terms of visuals for the previews in their settings").
///
/// Every pick-one setting draws a small picture per option, the way System
/// Settings → Appearance does: the picture, a blue ring on the one that is on,
/// the name under it, bold when chosen. The pictures were scored option by
/// option on a kit before any of this was built (scratchpad
/// `nota-settings-pictures.html`, artifact "Settings with pictures", rounds
/// 1–3); the drawings here are those drawings, coordinate for coordinate, in a
/// 68×44 space.
///
/// On/off switches keep their words (owner, same day: "skip on off switch"),
/// and long lists — models — stay menus, as long lists do in Apple's own
/// Settings. The glass row is not a tile row at all: it is Apple's Liquid Glass
/// row, one large live preview over real text (`SettingsGlassPreview`).
enum SettingsPictureMetrics {
  /// The tile, measured off System Settings → Appearance on 2026-10-30.
  static let tileSize = CGSize(width: 68, height: 44)
  static let tileCornerRadius: CGFloat = 6
  /// The selection ring and the gap between it and the tile.
  static let ringWidth: CGFloat = 2.5
  static let ringGap: CGFloat = 1.5
  /// The name under the tile. Wider than the tile so "Apple On-Device" sits
  /// on one line instead of breaking at its hyphen, and a three-word name
  /// wraps to two lines rather than three.
  static let labelSize: CGFloat = 11
  static let optionWidth: CGFloat = 88
  static let labelGap: CGFloat = 6
  static let optionSpacing: CGFloat = 14
}

// MARK: - Options

/// One option of a picture picker: the value it selects, its name, and its
/// drawing.
struct SettingsPictureOption<Value: Hashable>: Identifiable {
  let value: Value
  let label: String
  let picture: SettingsPicture

  var id: String { label }
}

/// Every picture row in the Settings window, each built from its enum's
/// `allCases` so a new case cannot ship without a tile —
/// `SettingsPictureTests` walks them.
enum SettingsPictureRows {
  static let appearance = AppearanceSetting.allCases.map {
    SettingsPictureOption(value: $0, label: $0.label, picture: .appearance($0))
  }
  static let closeSummary = SummaryRailDismissalBehavior.allCases.map {
    SettingsPictureOption(value: $0, label: $0.label, picture: .closeSummary($0))
  }
  static let activation = ActivationMode.allCases.map {
    SettingsPictureOption(value: $0, label: label(for: $0), picture: .activation($0))
  }
  static let trigger = TriggerKey.Kind.allCases.map {
    SettingsPictureOption(value: $0, label: label(for: $0), picture: .trigger($0))
  }
  static let engine = EngineChoice.allCases.map {
    SettingsPictureOption(value: $0, label: $0.label, picture: .engine($0))
  }
  static let delivery = DeliveryMode.allCases.map {
    SettingsPictureOption(value: $0, label: $0.label, picture: .delivery($0))
  }
  static let hudStyle = HUDStyle.allCases.map {
    SettingsPictureOption(value: $0, label: $0.label, picture: .hud($0))
  }
  static let cursorPosition = CursorMarkPosition.allCases.map {
    SettingsPictureOption(value: $0, label: $0.label, picture: .cursorPosition($0))
  }

  static func label(for mode: ActivationMode) -> String {
    switch mode {
    case .hold: return "Hold to dictate"
    case .toggle: return "Press to toggle"
    }
  }

  static func label(for kind: TriggerKey.Kind) -> String {
    switch kind {
    case .fnGlobe: return "Fn / Globe"
    case .keyCode: return "Custom key"
    }
  }
}

// MARK: - Picker

/// A row of picture tiles that picks one value. Each tile is a button carrying
/// its option's name and, when on, the selected trait; the row is one
/// contained group named by `title`, so VoiceOver reads "Activation, Hold to
/// dictate, selected" rather than a run of anonymous images.
struct SettingsPicturePicker<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [SettingsPictureOption<Value>]

  var body: some View {
    HStack(alignment: .top, spacing: SettingsPictureMetrics.optionSpacing) {
      ForEach(options) { option in
        SettingsPictureTile(
          option: option,
          isSelected: option.value == selection,
          select: { selection = option.value }
        )
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

private struct SettingsPictureTile<Value: Hashable>: View {
  let option: SettingsPictureOption<Value>
  let isSelected: Bool
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      VStack(spacing: SettingsPictureMetrics.labelGap) {
        SettingsPictureView(picture: option.picture)
          .frame(
            width: SettingsPictureMetrics.tileSize.width,
            height: SettingsPictureMetrics.tileSize.height
          )
          .clipShape(tileShape)
          .overlay(tileShape.strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
          .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
          .overlay {
            if isSelected {
              let outset = SettingsPictureMetrics.ringGap + SettingsPictureMetrics.ringWidth
              RoundedRectangle(
                cornerRadius: SettingsPictureMetrics.tileCornerRadius + outset,
                style: .continuous
              )
              .strokeBorder(Color.accentColor, lineWidth: SettingsPictureMetrics.ringWidth)
              .padding(-outset)
            }
          }
        // A no-break hyphen, so "Apple On-Device" wraps at a space rather
        // than splitting the word.
        Text(option.label.replacingOccurrences(of: "-", with: "\u{2011}"))
          .font(.system(
            size: SettingsPictureMetrics.labelSize,
            weight: isSelected ? .semibold : .regular
          ))
          .foregroundStyle(isSelected ? .primary : .secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(width: SettingsPictureMetrics.optionWidth)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(option.label)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var tileShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: SettingsPictureMetrics.tileCornerRadius, style: .continuous)
  }
}

// MARK: - Pictures

/// What a tile draws. One case per option, so the drawing is a function of the
/// value and nothing else.
enum SettingsPicture: Hashable {
  case appearance(AppearanceSetting)
  case closeSummary(SummaryRailDismissalBehavior)
  case activation(ActivationMode)
  case trigger(TriggerKey.Kind)
  case engine(EngineChoice)
  case delivery(DeliveryMode)
  case hud(HUDStyle)
  case cursorPosition(CursorMarkPosition)

  /// Where in the kit's loop the picture holds: the frame that says the most
  /// on its own. Insert on Release holds after the release — microphone off,
  /// every line in at once. Insert While Speaking holds mid-sentence —
  /// microphone still on, two lines typed and the third not yet. Review holds
  /// with the card up and nothing in the field. Delivery holds with its text in the field, or
  /// — for Review — with the card up and nothing inserted yet.
  var restingPhase: Double {
    switch self {
    case .delivery(.immediate): return 0.8
    case .delivery(.streaming): return 0.45
    case .delivery(.review): return 0.4
    default: return 0
    }
  }
}

/// Draws one picture, still, the way Apple's Appearance tiles are still.
///
/// The kit looped every picture, and the first build did too — measured
/// 2026-10-30, it cost what no settings page may. A tile is a cell of the
/// form's table, so each frame of one moving tile re-laid the whole form out:
/// ~40% CPU with all of them looping, for as long as the window existed
/// (another Space and behind other apps included; pausing on
/// `controlActiveState` did not stop it), and still ~30% with one tile
/// playing under the pointer. So each picture holds the frame that says the
/// most on its own (`SettingsPicture.restingPhase`), and the motion arithmetic
/// stays only as the means of drawing that frame.
struct SettingsPictureView: View {
  let picture: SettingsPicture
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let palette = SettingsPicturePalette(colorScheme)
    let picture = picture
    Canvas { context, _ in
      PicturePen(context: context, palette: palette, picture: picture).draw()
    }
    .accessibilityHidden(true)
  }
}

/// The picture colours, per theme. These are a drawing's colours, not the
/// form's: the tile ground, ink, key caps and fields of the kit, which were
/// scored in both themes.
struct SettingsPicturePalette {
  let tile, ink, ink2, keycap, keyedge, field, fieldLine, glass: Color
  let accent = Color.accentColor

  init(_ scheme: ColorScheme) {
    if scheme == .dark {
      tile = hex(0x3A3A3F); ink = hex(0xE6E6EA); ink2 = hex(0x7C7C84)
      keycap = hex(0x5A5A60); keyedge = hex(0x2A2A2E)
      field = hex(0x1C1C1E); fieldLine = hex(0x4A4A50)
      glass = Color(red: 12 / 255, green: 12 / 255, blue: 14 / 255).opacity(0.85)
    } else {
      tile = hex(0xE4E5EA); ink = hex(0x3A3A3F); ink2 = hex(0x9A9AA2)
      keycap = .white; keyedge = hex(0xB9B9C0)
      field = .white; fieldLine = hex(0xC7C7CD)
      glass = Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255).opacity(0.82)
    }
  }
}

private func hex(_ value: UInt32, _ alpha: Double = 1) -> Color {
  Color(
    red: Double((value >> 16) & 0xFF) / 255,
    green: Double((value >> 8) & 0xFF) / 255,
    blue: Double(value & 0xFF) / 255
  ).opacity(alpha)
}

// MARK: - Motion

/// The kit's keyframes as arithmetic, which is how a still picture finds the
/// opacities of the one frame it holds: piecewise linear stops over a loop
/// phase in [0, 1).
enum SettingsPictureMotion {
  /// Linear interpolation through `(phase, value)` stops, held flat outside
  /// them.
  static func keyframe(_ phase: Double, _ stops: [(Double, Double)]) -> Double {
    guard let first = stops.first, let last = stops.last else { return 0 }
    if phase <= first.0 { return first.1 }
    for (a, b) in zip(stops, stops.dropFirst()) where phase <= b.0 {
      let span = b.0 - a.0
      return span > 0 ? a.1 + (b.1 - a.1) * (phase - a.0) / span : b.1
    }
    return last.1
  }

  /// A line that appears at `at` and stays until the loop fades it out.
  static func appear(_ phase: Double, at: Double) -> Double {
    keyframe(phase, [(0, 0), (at - 0.02, 0), (at + 0.02, 1), (0.90, 1), (0.96, 0), (1, 0)])
  }

  /// The microphone dot: lit from the press until `until`.
  static func mic(_ phase: Double, until: Double) -> Double {
    keyframe(phase, [(0, 0.25), (0.02, 0.25), (0.04, 1), (until, 1), (until + 0.03, 0.25), (1, 0.25)])
  }
}

// MARK: - Drawing

/// Draws one picture into a 68×44 Canvas. The coordinates are the kit's SVG
/// coordinates, unchanged, so a tile can be checked against the scored kit
/// shape by shape.
private struct PicturePen {
  let context: GraphicsContext
  let palette: SettingsPicturePalette
  let picture: SettingsPicture

  private let full = CGRect(x: 0, y: 0, width: 68, height: 44)

  func draw() {
    switch picture {
    case .appearance(let mode): appearance(mode)
    case .closeSummary(let kind): closeSummary(kind)
    case .activation(let mode): activation(mode)
    case .trigger(let kind): trigger(kind)
    case .engine(let choice): engine(choice)
    case .delivery(let mode): delivery(mode)
    case .hud(let style): hud(style)
    case .cursorPosition(let position): cursorPosition(position)
    }
  }

  // MARK: Primitives

  private func rect(
    _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat = 0,
    _ color: Color, in ctx: GraphicsContext? = nil
  ) {
    let path = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    (ctx ?? context).fill(path, with: .color(color))
  }

  /// A filled rounded rect with a hairline stroke — the kit's field and key
  /// cap classes.
  private func stroked(
    _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat,
    fill: Color, stroke: Color, width: CGFloat = 0.6, in ctx: GraphicsContext? = nil
  ) {
    let path = Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    let c = ctx ?? context
    c.fill(path, with: .color(fill))
    c.stroke(path, with: .color(stroke), lineWidth: width)
  }

  private func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: Color) {
    context.fill(
      Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
      with: .color(color)
    )
  }

  /// A meter bar. The kit's bars bobbed; held still, a meter reads as a row
  /// of bars of different heights, so each takes a fixed fraction of `h`
  /// about its own vertical centre.
  private func bar(
    _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, r: CGFloat, _ color: Color,
    index: Int
  ) {
    let levels: [CGFloat] = [0.55, 1, 0.75, 0.9, 0.6, 0.8]
    let scaled = h * levels[index % levels.count]
    rect(x, y + (h - scaled) / 2, w, scaled, r: min(r, scaled / 2), color)
  }

  private var glassStroke: Color { .white.opacity(0.28) }
  private var phase: Double { picture.restingPhase }

  // MARK: Appearance — Apple's own tile: wallpaper, a back window, a front
  // window with traffic lights.

  private func appearance(_ mode: AppearanceSetting) {
    func wallpaper(dark: Bool, in ctx: GraphicsContext) {
      let stops: [Gradient.Stop] = [
        .init(color: hex(0x2A4FC9), location: 0),
        .init(color: hex(dark ? 0x2C4AA8 : 0x5D8DF7), location: 0.55),
        .init(color: hex(dark ? 0x2A3A7A : 0xA9CBFF), location: 1),
      ]
      ctx.fill(
        Path(full),
        with: .linearGradient(
          Gradient(stops: stops), startPoint: .zero, endPoint: CGPoint(x: 68, y: 44)
        )
      )
      var swoosh = Path()
      swoosh.move(to: CGPoint(x: 0, y: 30))
      swoosh.addCurve(
        to: CGPoint(x: 68, y: 20),
        control1: CGPoint(x: 18, y: 16), control2: CGPoint(x: 38, y: 40)
      )
      swoosh.addLine(to: CGPoint(x: 68, y: 44))
      swoosh.addLine(to: CGPoint(x: 0, y: 44))
      swoosh.closeSubpath()
      ctx.fill(swoosh, with: .color(hex(0xD6E6FF, 0.5)))
    }
    func scene(dark: Bool, in ctx: GraphicsContext) {
      let window = hex(dark ? 0x1F1F24 : 0xF6F6F8)
      let bar = hex(dark ? 0x4A4B55 : 0xC9CAD2)
      rect(4, 5, 46, 21, r: 3, window, in: ctx)
      rect(7, 9, 30, 4, r: 2, hex(0x3D7BF5), in: ctx)
      rect(7, 16, 20, 2.5, r: 1.2, bar, in: ctx)
      rect(30, 21, 34, 19, r: 3, window, in: ctx)
      for (i, light) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        let cx = 35.5 + CGFloat(i) * 5
        ctx.fill(
          Path(ellipseIn: CGRect(x: cx - 1.7, y: 30.5 - 1.7, width: 3.4, height: 3.4)),
          with: .color(hex(UInt32(light)))
        )
      }
    }

    switch mode {
    case .light:
      wallpaper(dark: false, in: context)
      scene(dark: false, in: context)
    case .dark:
      wallpaper(dark: true, in: context)
      scene(dark: true, in: context)
    case .system:
      wallpaper(dark: false, in: context)
      var left = context
      left.clip(to: polygon([(0, 0), (42, 0), (26, 44), (0, 44)]))
      scene(dark: false, in: left)
      var right = context
      right.clip(to: polygon([(42, 0), (68, 0), (68, 44), (26, 44)]))
      right.fill(Path(full), with: .color(hex(0x1D2A66, 0.55)))
      scene(dark: true, in: right)
    }
  }

  private func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
    var path = Path()
    path.addLines(points.map { CGPoint(x: $0.0, y: $0.1) })
    path.closeSubpath()
    return path
  }

  // MARK: Closing the summary — the window with its summary panel open.

  private func closeSummary(_ kind: SummaryRailDismissalBehavior) {
    let p = palette
    context.fill(Path(full), with: .color(p.tile))
    stroked(5, 5, 58, 34, r: 3, fill: p.field, stroke: p.fieldLine)
    for (y, w) in [(11, 22), (16, 18), (21, 21), (26, 15)] as [(CGFloat, CGFloat)] {
      rect(9, y, w, 2.4, r: 1.2, p.ink2)
    }
    switch kind {
    case .save:
      // The panel goes (dashed), the draft is kept (the check).
      context.stroke(
        Path(roundedRect: CGRect(x: 36, y: 8, width: 24, height: 28), cornerRadius: 2.5),
        with: .color(p.ink.opacity(0.55)),
        style: StrokeStyle(lineWidth: 0.7, dash: [2, 1.6])
      )
      rect(39, 12, 16, 2.4, r: 1.2, p.accent.opacity(0.7))
      circle(48, 25, 6, hex(0x34C759))
      var check = Path()
      check.move(to: CGPoint(x: 45, y: 25.2))
      check.addLine(to: CGPoint(x: 47.1, y: 27.4))
      check.addLine(to: CGPoint(x: 51.1, y: 23))
      context.stroke(
        check, with: .color(.white),
        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
      )
    case .ask:
      // The panel stays, and a dialog asks with three buttons.
      rect(36, 8, 24, 28, r: 2.5, p.tile.opacity(0.9))
      rect(39, 12, 16, 2.4, r: 1.2, p.accent.opacity(0.7))
      var shadowed = context
      shadowed.addFilter(.shadow(color: .black.opacity(0.25), radius: 1.5, y: 1))
      stroked(15, 12, 34, 21, r: 3.5, fill: p.field, stroke: p.fieldLine, in: shadowed)
      rect(22, 16, 20, 2.4, r: 1.2, p.ink)
      rect(18.5, 25, 8, 4, r: 1.6, p.ink2)
      rect(28, 25, 8, 4, r: 1.6, p.ink2)
      rect(37.5, 25, 8, 4, r: 1.6, p.accent)
    }
  }

  // MARK: Activation — when the key is down, drawn as a timeline under the
  // sound bars (round 2, option B).

  private func activation(_ mode: ActivationMode) {
    let p = palette
    context.fill(Path(full), with: .color(p.tile))
    for i in 0..<6 {
      bar(23 + CGFloat(i) * 4, 7, 2.4, 13, r: 1.2, p.ink, index: i)
    }
    rect(20.5, 22, 0.6, 6, p.ink2)
    rect(47.5, 22, 0.6, 6, p.ink2)
    rect(6, 31.3, 56, 1, r: 0.5, p.ink2)
    switch mode {
    case .hold:
      rect(19, 28.5, 30, 6.5, r: 3.25, p.accent)
    case .toggle:
      rect(18, 28, 4.5, 7.5, r: 2.2, p.accent)
      rect(45.5, 28, 4.5, 7.5, r: 2.2, p.accent)
    }
  }

  // MARK: Trigger key — a keyboard with the key lit.

  private func trigger(_ kind: TriggerKey.Kind) {
    let p = palette
    context.fill(Path(full), with: .color(p.tile))
    for row in 0..<3 {
      for col in 0..<7 {
        stroked(
          4 + CGFloat(col) * 8.6 + CGFloat(row % 2) * 2, 5 + CGFloat(row) * 8.6, 7, 7,
          r: 1.4, fill: p.keycap, stroke: p.keyedge
        )
      }
    }
    let fn = kind == .fnGlobe
    let lit = (fill: p.accent, stroke: p.accent)
    let cap = (fill: p.keycap, stroke: p.keyedge)
    let fnKey = fn ? lit : cap
    let space = fn ? cap : lit
    stroked(4, 31, 9, 8, r: 1.6, fill: fnKey.fill, stroke: fnKey.stroke)
    stroked(14.5, 31, 7, 8, r: 1.4, fill: p.keycap, stroke: p.keyedge)
    stroked(23, 31, 30, 8, r: 1.6, fill: space.fill, stroke: space.stroke)
    stroked(54.5, 31, 9, 8, r: 1.4, fill: p.keycap, stroke: p.keyedge)
    if fn {
      var globe = Path(ellipseIn: CGRect(x: 5.9, y: 32.4, width: 5.2, height: 5.2))
      globe.addEllipse(in: CGRect(x: 7.3, y: 32.4, width: 2.4, height: 5.2))
      globe.move(to: CGPoint(x: 5.9, y: 35))
      globe.addLine(to: CGPoint(x: 11.1, y: 35))
      context.stroke(globe, with: .color(.white), lineWidth: 0.7)
    }
  }

  // MARK: Recognition engine — on the laptop, or sent up to a cloud.

  private func engine(_ choice: EngineChoice) {
    let p = palette
    context.fill(Path(full), with: .color(p.tile))
    func laptop(_ x: CGFloat, _ w: CGFloat) {
      let h = w * 0.62
      stroked(x, 8, w, h, r: 2, fill: p.field, stroke: p.fieldLine)
      context.fill(
        polygon([(x - 4, 8 + h + 1), (x + w + 4, 8 + h + 1), (x + w + 2, 8 + h + 4), (x - 2, 8 + h + 4)]),
        with: .color(p.ink2)
      )
    }
    switch choice {
    case .apple:
      laptop(16, 36)
      for i in 0..<5 {
        bar(25 + CGFloat(i) * 4, 12, 2.2, 13, r: 1.1, p.accent, index: i)
      }
    case .assemblyAIRealtime:
      laptop(8, 24)
      for i in 0..<3 {
        rect(14 + CGFloat(i) * 4, 12, 2.2, 7, r: 1.1, p.ink2)
      }
      var arrow = Path()
      arrow.move(to: CGPoint(x: 36, y: 21))
      arrow.addLine(to: CGPoint(x: 44, y: 21))
      arrow.move(to: CGPoint(x: 42, y: 18.5))
      arrow.addLine(to: CGPoint(x: 44.5, y: 21))
      arrow.addLine(to: CGPoint(x: 42, y: 23.5))
      context.stroke(
        arrow, with: .color(p.accent),
        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
      )
      // The kit's cloud is three SVG arcs; here it is three discs on a base,
      // drawn twice — a hair larger in the line colour, then in the field
      // colour — so the outline survives where the discs overlap.
      for (grow, color) in [(0.6, p.fieldLine), (0, p.field)] as [(CGFloat, Color)] {
        var cloud = Path(roundedRect: CGRect(x: 49.5 - grow, y: 21.5 - grow, width: 13 + 2 * grow, height: 5.5 + 2 * grow), cornerRadius: 2.75 + grow)
        cloud.addEllipse(in: CGRect(x: 49 - grow, y: 18 - grow, width: 8 + 2 * grow, height: 8 + 2 * grow))
        cloud.addEllipse(in: CGRect(x: 52 - grow, y: 14.8 - grow, width: 10.4 + 2 * grow, height: 10.4 + 2 * grow))
        context.fill(cloud, with: .color(color))
      }
      for i in 0..<3 {
        bar(52.5 + CGFloat(i) * 3.3, 19, 1.9, 6, r: 0.9, p.accent, index: i)
      }
    }
  }

  // MARK: Delivery — a text field in the app being dictated into; the lines
  // arrive on each mode's schedule.

  private func delivery(_ mode: DeliveryMode) {
    let p = palette
    let phase = self.phase
    context.fill(Path(full), with: .color(p.tile))
    stroked(5, 14, 58, 25, r: 2.5, fill: p.field, stroke: p.fieldLine)
    func line(_ y: CGFloat, _ w: CGFloat, at: Double) {
      rect(9, y, w, 2.6, r: 1.3, p.ink.opacity(SettingsPictureMotion.appear(phase, at: at)))
    }
    func mic(until: Double) {
      circle(9, 7.5, 2.4, hex(0xFF453A, SettingsPictureMotion.mic(phase, until: until)))
    }
    switch mode {
    case .immediate:
      mic(until: 0.55)
      rect(14, 6.3, 18, 2.4, r: 1.2, p.ink2)
      line(19, 44, at: 0.60)
      line(25, 38, at: 0.60)
      line(31, 26, at: 0.60)
    case .streaming:
      mic(until: 0.70)
      rect(14, 6.3, 18, 2.4, r: 1.2, p.ink2)
      line(19, 44, at: 0.20)
      line(25, 38, at: 0.38)
      line(31, 26, at: 0.56)
    case .review:
      mic(until: 0.44)
      line(19, 44, at: 0.68)
      line(25, 38, at: 0.68)
      line(31, 26, at: 0.68)
      let cardOpacity = SettingsPictureMotion.keyframe(
        phase, [(0, 0), (0.04, 0), (0.08, 1), (0.58, 1), (0.64, 0), (1, 0)]
      )
      let cardDrop = SettingsPictureMotion.keyframe(
        phase, [(0, 2), (0.04, 2), (0.08, 0), (0.58, 0), (0.64, 4), (1, 4)]
      )
      var card = context
      card.opacity = cardOpacity
      card.translateBy(x: 0, y: cardDrop)
      stroked(15, 3, 47, 22, r: 3.5, fill: p.glass, stroke: glassStroke, width: 0.5, in: card)
      let first = SettingsPictureMotion.keyframe(phase, [(0, 0), (0.10, 0), (0.14, 1), (1, 1)])
      let second = SettingsPictureMotion.keyframe(phase, [(0, 0), (0.26, 0), (0.30, 1), (1, 1)])
      rect(19, 7.5, 30, 2.4, r: 1.2, .white.opacity(0.88 * first), in: card)
      rect(19, 12, 22, 2.4, r: 1.2, .white.opacity(0.88 * second), in: card)
      // Apply, pressed at the moment the card goes.
      let press = SettingsPictureMotion.keyframe(
        phase, [(0, 1), (0.47, 1), (0.50, 0.8), (0.54, 1), (1, 1)]
      )
      let w = 11 * press, h = 4.5 * press
      rect(53.5 - w / 2, 20.25 - h / 2, w, h, r: 2.2 * press, p.accent, in: card)
    }
  }

  // MARK: HUD style — a window on a desktop, and the HUD where it sits.

  private func hud(_ style: HUDStyle) {
    context.fill(Path(full), with: .color(hex(0x4A5A86)))
    rect(5, 4, 58, 27, r: 2.5, hex(0xF3F3F6))
    for (y, w) in [(9, 30), (14, 40), (19, 24)] as [(CGFloat, CGFloat)] {
      rect(9, y, w, 2.4, r: 1.2, hex(0xB7B9C4))
    }
    func meter(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat) {
      for i in 0..<4 {
        bar(x + CGFloat(i) * 2.2, y, 1.3, h, r: 0.6, .white, index: i)
      }
    }
    let dim = Color.white.opacity(0.45), bright = Color.white.opacity(0.88)
    let glass = palette.glass
    switch style {
    case .pill:
      stroked(18, 27, 32, 14, r: 6, fill: glass, stroke: glassStroke, width: 0.5)
      meter(30.5, 28.6, 3.2)
      rect(22, 33.4, 24, 1.8, r: 0.9, dim)
      rect(22, 36.8, 18, 1.8, r: 0.9, bright)
    case .bar:
      stroked(6, 34, 56, 7, r: 3.5, fill: glass, stroke: glassStroke, width: 0.5)
      circle(10.5, 37.5, 1.4, .white)
      meter(14, 35.6, 3.8)
      rect(25, 36.6, 10, 1.8, r: 0.9, dim)
      rect(36, 36.6, 22, 1.8, r: 0.9, bright)
    case .prompter:
      stroked(9, 20, 50, 21, r: 3.5, fill: glass, stroke: glassStroke, width: 0.5)
      meter(13, 23, 2.6)
      rect(13, 28.4, 40, 1.8, r: 0.9, bright)
      rect(13, 32, 36, 1.8, r: 0.9, bright)
      rect(13, 35.6, 26, 1.8, r: 0.9, dim)
    case .cursor:
      rect(9, 24.4, 22, 2.4, r: 1.2, hex(0x6F7280))
      rect(31.6, 23, 0.8, 5.2, hex(0x2A6EF6))
      let path = Path(ellipseIn: CGRect(x: 33.9, y: 23, width: 5.2, height: 5.2))
      context.fill(path, with: .color(Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255).opacity(0.82)))
      context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.4)
    }
  }

  // MARK: Cursor position — the mark beside the caret, or under it.

  private func cursorPosition(_ position: CursorMarkPosition) {
    let p = palette
    context.fill(Path(full), with: .color(p.tile))
    stroked(5, 9, 58, 26, r: 2.5, fill: p.field, stroke: p.fieldLine)
    rect(10, 19, 22, 2.6, r: 1.3, p.ink2)
    rect(32.6, 17, 0.9, 6.6, p.accent)
    let (cx, cy): (CGFloat, CGFloat) = position == .beside ? (41, 20.3) : (33, 28.5)
    stroked(
      cx - 5.5, cy - 2.6, 11, 5.2, r: 2.6,
      fill: Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255).opacity(0.82),
      stroke: .white.opacity(0.35), width: 0.4
    )
    for i in 0..<4 {
      bar(cx - 3.3 + CGFloat(i) * 2, cy - 1.6, 1, 3.2, r: 0.5, .white, index: i)
    }
  }
}

// MARK: - Glass preview

/// Apple's Liquid Glass row: one large live preview, over real text, of the
/// glass the HUD pill and the review card are made of.
///
/// Same material and same tint as the HUD: `GlassMaterial` picks `.regular` or
/// `.clear` Liquid Glass, and the dark cast is `GlassTint`'s colour at the
/// slider's alpha, drawn above the glass the way `GlassBackingView` draws its
/// tint overlay. What differs is who draws the glass. The HUD's AppKit plate
/// (`NSGlassEffectView`) was tried here first on 2026-10-30, and in the one
/// check made — a capture of the window while it sat on another Space — it
/// never showed the text behind it, so Frosted and Clear came out identical — the exact complaint the preview exists to answer. SwiftUI's
/// `.glassEffect` refracts its own hierarchy, and the text *is* in it; that is
/// the case CLAUDE.md marks as correct for SwiftUI glass (inside the main
/// window), and the floating-panel trap is the opposite case.
///
/// The text is there on purpose: the kit's first glass tiles sat over flat
/// colour, and blur only shows over something sharp (owner, round 2: "can't see
/// the difference").
struct SettingsGlassPreview: View {
  let material: GlassMaterial
  let tintAlpha: Double

  static let size = CGSize(width: 300, height: 184)
  static let pillSize = CGSize(width: 200, height: 52)

  var body: some View {
    ZStack(alignment: .bottom) {
      backdrop
      ZStack {
        Capsule()
          .fill(Color(nsColor: GlassTint.color(alpha: tintAlpha)))
          .liquidGlass(material == .clear ? .clear : .regular, in: Capsule())
        pillContent
      }
      .frame(width: Self.pillSize.width, height: Self.pillSize.height)
      .padding(.bottom, 26)
    }
    .frame(width: Self.size.width, height: Self.size.height)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .environment(\.colorScheme, .light)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Preview of the dictation glass, \(material.label)")
  }

  /// A page of meeting notes on a warm, colourful ground — something sharp
  /// for the glass to blur or let through.
  private var backdrop: some View {
    ZStack(alignment: .topLeading) {
      hex(0xF4EFE6)
      RadialGradient(
        colors: [hex(0xFF9A62), hex(0xFF9A62, 0)],
        center: UnitPoint(x: 0.15, y: 0.2), startRadius: 0, endRadius: 150
      )
      RadialGradient(
        colors: [hex(0x5B8CFF), hex(0x5B8CFF, 0)],
        center: UnitPoint(x: 0.85, y: 0.3), startRadius: 0, endRadius: 150
      )
      RadialGradient(
        colors: [hex(0x3FD0A4), hex(0x3FD0A4, 0)],
        center: UnitPoint(x: 0.6, y: 0.95), startRadius: 0, endRadius: 160
      )
      VStack(alignment: .leading, spacing: 6) {
        Text("Q3 launch review")
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(hex(0xC2410C))
        Text("We agreed to move the launch to the 14th so the onboarding fixes ship with it. Kenny owns the release notes; Brian checks the billing flow on staging before Friday.")
        Text("Open: who tells support, and when.")
      }
      .font(.system(size: 14, weight: .semibold))
      .lineSpacing(2)
      // The row is trailing-aligned in the form, and multi-line text inherits
      // that; a page of notes reads from the left.
      .multilineTextAlignment(.leading)
      .foregroundStyle(hex(0x1D1D24))
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }

  private var pillContent: some View {
    HStack(spacing: 10) {
      Circle().fill(.white).frame(width: 9, height: 9)
      meter
      Text("we agreed to move the launch")
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
    .padding(.horizontal, 18)
  }

  /// A still meter, for the reason the tiles are still
  /// (`SettingsPictureView`) — and this one sits under glass, which
  /// recomposites under anything that moves.
  private var meter: some View {
    HStack(spacing: 2) {
      ForEach(Array([0.5, 0.9, 0.65, 1, 0.55].enumerated()), id: \.offset) { _, height in
        Capsule()
          .fill(.white)
          .frame(width: 3, height: 18 * height)
      }
    }
    .frame(height: 18)
  }
}
