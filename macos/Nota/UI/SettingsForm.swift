import SwiftUI

/// **The Settings window's one form grammar** (P-D10).
///
/// Six tabs were writing the same three things three ways: the caption under a
/// control was inlined twelve times in `SettingsView`, declared privately in
/// `DictationSettingsView`, and declared privately a third time in
/// `DictionarySettingsView`; control labels alternated between
/// Title Case and sentence case row to row; and whether a picker showed its own
/// label was decided per picker. This is the one place those answers live, so a
/// new pane inherits the grammar instead of inventing a fourth copy of it.
///
/// The rules, written down because they are the part a constant cannot carry:
///
/// - **A control's label is sentence case.** A label names a thing; a *button*
///   commands one, and buttons are Title Case (Apple HIG, and what the app
///   already does — `Save Transcript`, `Check for New Models`, `Manage
///   Dictionary…`). Section **headers** are Title Case too, because they title a
///   region rather than label a control: "Recognition Engine", "Heads-Up
///   Display", "Custom Dictionary".
/// - **A picker hides its label exactly when the label would repeat the section
///   header.** `Picker("Activation")` under a header reading "Activation" is the
///   word twice, so it takes `.labelsHidden()`. Two pickers sharing one section
///   — Style and Glass material under "Heads-Up Display" — must both keep
///   theirs, or the section is two anonymous radio groups.
/// - **A caption is `SettingsCaption`.** Never a hand-rolled
///   `.font(…).foregroundStyle(.secondary)` pair, which is how the three tabs
///   drifted apart in the first place. A caption that is not secondary (a
///   tertiary status, a red error) takes `.settingsCaptionFont()` and states its
///   own colour.
enum SettingsForm {
  /// The width every tab is laid out at. Height is per tab: a sparse tab must
  /// not float in blank space and a dense one must not scroll inside a short
  /// window.
  static let windowWidth: CGFloat = 720

  /// The gap inside a label/caption pair, and between the caption lines of one
  /// footer. They are one stack, so they take one number.
  static let captionSpacing: CGFloat = Metrics.tightStackSpacing
}

// MARK: - Captions

/// One line of secondary explanatory text under a control or in a section
/// footer. The whole of the Settings window's caption style.
struct SettingsCaption: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(Tokens.settingsCaptionFont)
      .foregroundStyle(.secondary)
  }
}

/// A section footer of several caption lines, stacked at the form's one spacing.
struct SettingsFooter<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsForm.captionSpacing) {
      content
    }
  }
}

/// A control's label with its caption underneath — the shape the General tab's
/// toggles and pickers all take.
struct SettingsLabel: View {
  let title: String
  let caption: String

  init(_ title: String, caption: String) {
    self.title = title
    self.caption = caption
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsForm.captionSpacing) {
      Text(title)
      SettingsCaption(caption)
    }
  }
}

extension View {
  /// The caption *face* alone, for the captions that are deliberately not
  /// secondary: a tertiary status value, a red error line.
  func settingsCaptionFont() -> some View {
    font(Tokens.settingsCaptionFont)
  }
}
