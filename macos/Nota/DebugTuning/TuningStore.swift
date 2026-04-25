#if DEBUG
import Foundation
import SwiftUI

@MainActor
final class TuningStore: ObservableObject {
  static let shared = TuningStore()

  @Published var statusPillH: CGFloat
  @Published var statusPillV: CGFloat
  @Published var statusHStackSpacing: CGFloat
  @Published var toolbarStatusTintOpacity: Double

  @Published var newButtonH: CGFloat
  @Published var newButtonV: CGFloat
  @Published var newButtonStackSpacing: CGFloat
  @Published var primaryActionCornerRadius: CGFloat
  @Published var primaryActionTintOpacity: Double

  @Published var dropCornerRadius: CGFloat
  @Published var dropTargetStrokeWidth: CGFloat
  @Published var dropStrokeIdle: CGFloat
  @Published var dropStrokeActive: CGFloat

  @Published var emptyMainSpacing: CGFloat
  @Published var emptyMainOuterPadding: CGFloat
  @Published var emptyTextSpacing: CGFloat
  @Published var emptySubtextHorizontalPadding: CGFloat

  init() {
    self.statusPillH = Metrics.statusPillH
    self.statusPillV = Metrics.statusPillV
    self.statusHStackSpacing = Metrics.statusHStackSpacing
    self.toolbarStatusTintOpacity = Tokens.toolbarStatusTintOpacity

    self.newButtonH = Metrics.newButtonH
    self.newButtonV = Metrics.newButtonV
    self.newButtonStackSpacing = Metrics.newButtonStackSpacing
    self.primaryActionCornerRadius = Metrics.primaryActionCornerRadius
    self.primaryActionTintOpacity = Tokens.primaryActionTintOpacity

    self.dropCornerRadius = Metrics.dropCornerRadius
    self.dropTargetStrokeWidth = Metrics.dropTargetStrokeWidth
    self.dropStrokeIdle = Metrics.dropStrokeIdle
    self.dropStrokeActive = Metrics.dropStrokeActive

    self.emptyMainSpacing = Metrics.emptyMainSpacing
    self.emptyMainOuterPadding = Metrics.emptyMainOuterPadding
    self.emptyTextSpacing = Metrics.emptyTextSpacing
    self.emptySubtextHorizontalPadding = Metrics.emptySubtextHorizontalPadding
  }

  func resetToDefaults() {
    statusPillH = Metrics.statusPillH
    statusPillV = Metrics.statusPillV
    statusHStackSpacing = Metrics.statusHStackSpacing
    toolbarStatusTintOpacity = Tokens.toolbarStatusTintOpacity

    newButtonH = Metrics.newButtonH
    newButtonV = Metrics.newButtonV
    newButtonStackSpacing = Metrics.newButtonStackSpacing
    primaryActionCornerRadius = Metrics.primaryActionCornerRadius
    primaryActionTintOpacity = Tokens.primaryActionTintOpacity

    dropCornerRadius = Metrics.dropCornerRadius
    dropTargetStrokeWidth = Metrics.dropTargetStrokeWidth
    dropStrokeIdle = Metrics.dropStrokeIdle
    dropStrokeActive = Metrics.dropStrokeActive

    emptyMainSpacing = Metrics.emptyMainSpacing
    emptyMainOuterPadding = Metrics.emptyMainOuterPadding
    emptyTextSpacing = Metrics.emptyTextSpacing
    emptySubtextHorizontalPadding = Metrics.emptySubtextHorizontalPadding
  }
}
#endif
