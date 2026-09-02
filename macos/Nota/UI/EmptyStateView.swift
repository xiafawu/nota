import SwiftUI

/// One grammar for every place the app has nothing to show (P-D4).
///
/// Before this existed the six empty states used six scales — 72 / 28 / no
/// icon, `.title` / `.callout` / 13pt medium / no title, centered and leading —
/// so a drawer with no transcripts and a Speakers pane with no voiceprints,
/// both "a list in a narrow column with nothing in it", shared nothing. The
/// token table had already declared the grammar and nothing read it:
/// `Tokens.emptyHistoryIconFont` / `emptyHistoryLabelFont` /
/// `emptyHistoryHelperFont` over `Metrics.emptyHistoryStackSpacing`. That trio
/// is the one this view draws, and it is now the only trio any in-panel empty
/// state may use.
///
/// `EmptyMainView` deliberately does **not** use it: the full-window idle state
/// is a different scale on purpose (72pt), and its running layout is a progress
/// surface rather than an empty state at all.
struct EmptyStateView<Accessory: View>: View {
  /// Which ink a surface may spend. The two 380pt glass panels float on the
  /// morphing field, so their text takes a measured `GroundInk` tier exactly as
  /// `SummaryRailView`'s notice does; Settings tabs and the Usage sheet sit on
  /// the system window background, where the semantic colours are correct.
  enum Ink {
    case field
    case system
  }

  let icon: String
  let title: String
  var helpers: [String] = []
  var alignment: HorizontalAlignment = .center
  var ink: Ink = .system
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    VStack(alignment: alignment, spacing: Metrics.emptyHistoryStackSpacing) {
      Image(systemName: icon)
        .font(Tokens.emptyHistoryIconFont)
        .foregroundStyle(iconStyle)

      Text(title)
        .font(Tokens.emptyHistoryLabelFont)
        .foregroundStyle(titleStyle)
        .multilineTextAlignment(textAlignment)

      ForEach(Array(helpers.enumerated()), id: \.offset) { _, helper in
        Text(helper)
          .font(Tokens.emptyHistoryHelperFont)
          .foregroundStyle(helperStyle)
          .multilineTextAlignment(textAlignment)
          .fixedSize(horizontal: false, vertical: true)
      }

      accessory()
    }
    .frame(maxWidth: .infinity, alignment: frameAlignment)
  }

  private var textAlignment: TextAlignment {
    alignment == .leading ? .leading : .center
  }

  private var frameAlignment: Alignment {
    alignment == .leading ? .leading : .center
  }

  private var iconStyle: AnyShapeStyle {
    switch ink {
    case .field: return AnyShapeStyle(.ground(.timestamp))
    case .system: return AnyShapeStyle(.secondary)
    }
  }

  private var titleStyle: AnyShapeStyle {
    switch ink {
    case .field: return AnyShapeStyle(.ground(.body))
    case .system: return AnyShapeStyle(.secondary)
    }
  }

  private var helperStyle: AnyShapeStyle {
    switch ink {
    case .field: return AnyShapeStyle(.ground(.speaker))
    case .system: return AnyShapeStyle(.tertiary)
    }
  }
}

extension EmptyStateView where Accessory == EmptyView {
  init(
    icon: String,
    title: String,
    helpers: [String] = [],
    alignment: HorizontalAlignment = .center,
    ink: Ink = .system
  ) {
    self.init(
      icon: icon,
      title: title,
      helpers: helpers,
      alignment: alignment,
      ink: ink,
      accessory: { EmptyView() }
    )
  }
}
