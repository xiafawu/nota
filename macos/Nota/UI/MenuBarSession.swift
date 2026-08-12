import SwiftUI

// MARK: - The bar itself

/// What the menu-bar item says about a live session, as a pure decision
/// (XIA-434).
///
/// The elapsed time is **in the bar itself**, not only in the menu: the status
/// item is the one thing on screen in every app, on every Space, and a session
/// you cannot see the length of is a session you have to go and look up.
/// Elastic width is fine — `MenuBarExtra` lays its label out at whatever size it
/// asks for — but the digits are tabular so the item does not breathe once a
/// second.
struct MenuBarSessionPresence: Equatable {
  /// Whether the dot is drawn in ember.
  ///
  /// **Ember means the microphone is open and nothing else.** A stopping
  /// session's tap is still installed and every buffer is being dropped, so its
  /// dot goes out at exactly the moment the meter's does — one rule, one
  /// predicate (`LiveMeetingSession.meterFollowsMicrophone`), two surfaces.
  let isEmber: Bool
  /// "07:41", and "1:12:40" past the hour. Through `SessionTimerMetrics` — the
  /// one clock — so the bar, the island and the window can never disagree by a
  /// rounding change.
  let elapsed: String

  /// Nil when there is no session to be present about.
  static func make(
    state: LiveMeetingSession.SessionState,
    elapsed: TimeInterval
  ) -> MenuBarSessionPresence? {
    switch state {
    case .idle:
      return nil
    case .recording, .stopping, .failed:
      return MenuBarSessionPresence(
        isEmber: LiveMeetingSession.meterFollowsMicrophone(state),
        elapsed: LiveMeetingFormat.duration(elapsed)
      )
    }
  }

  var accessibilityLabel: String {
    isEmber ? "Nota: recording, \(elapsed)" : "Nota: session stopped, \(elapsed)"
  }
}

/// The live-session slot of the menu-bar label.
///
/// Its own leaf view holding `@ObservedObject var session`, so the once-a-second
/// `elapsed` re-runs *this* body and nothing above it — the same split
/// `SessionMeterFeedView` makes for the microphone's feed, one order of
/// magnitude slower.
/// **The ember here is the system's, not `.dark`.** The island pins its panel to
/// `.darkAqua` and is right to hard-code the lifted dark ember; the status item
/// and the popover follow whatever the Mac is set to, and `#e8823a` — a value
/// chosen to survive the smoky dark wash — reads as washed-out orange in Light
/// rather than as the one reserved signal colour.
struct MenuBarSessionLabel: View {
  @ObservedObject var session: LiveMeetingSession

  var body: some View {
    if let presence = MenuBarSessionPresence.make(state: session.state, elapsed: session.elapsed) {
      MenuBarPresenceLabel(presence: presence)
    }
  }
}

/// What the bar actually draws, split off the observing wrapper so its width can
/// be **measured** rather than only its string asserted: a `.frame(width:)` or a
/// dropped `lineLimit` would clip "1:12:40" to "1:12:…" in the status item, and
/// no assertion about `MenuBarSessionPresence.elapsed` can see that.
struct MenuBarPresenceLabel: View {
  let presence: MenuBarSessionPresence
  /// **The system's, not `.dark`.** See `MenuBarSessionLabel`.
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 3) {
      Circle()
        .fill(presence.isEmber ? CraftTokens.ember(colorScheme) : Color.secondary)
        .frame(width: 7, height: 7)
      Text(presence.elapsed)
        .font(.caption)
        .monospacedDigit()
        .lineLimit(1)
        // The bar is elastic; the digits are tabular so it does not breathe
        // once a second, and the text is never given a width to be cut to.
        .fixedSize()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(presence.accessibilityLabel)
    .help(presence.accessibilityLabel)
  }
}

// MARK: - The menu

/// The rows the popover gains while a session is running, as a table.
enum SessionMenuRow: CaseIterable, Equatable {
  case mark
  case stop

  var title: String {
    switch self {
    case .mark: return MenuBarSessionCopy.markTitle
    case .stop: return MenuBarSessionCopy.stopTitle
    }
  }

  /// The island's own verb, so one press of ⌘K means one thing wherever it is
  /// pressed.
  var action: MiniIslandAction {
    switch self {
    case .mark: return .mark
    case .stop: return .stop
    }
  }
}

enum MenuBarSessionCopy {
  static let markTitle = "Mark this moment"
  static let stopTitle = "Stop & summarize"

  /// The status row: what the session is doing, and for how long.
  static func status(state: LiveMeetingSession.SessionState, elapsed: TimeInterval) -> String {
    "\(LiveMeetingFormat.stateLabel(state)) · \(LiveMeetingFormat.duration(elapsed))"
  }
}

/// Which rows a state offers.
///
/// Both verbs need a live microphone: Mark writes a timestamp into a session
/// that is running, and Stop is refused by `NotaModel` for anything it does not
/// own. A stopping or failed session shows the status row and no verbs — the
/// failed one's decisions (Save Transcript / Try Again / Discard) are the
/// window's, where the transcript they are about is.
enum SessionMenuRows {
  static func rows(state: LiveMeetingSession.SessionState) -> [SessionMenuRow] {
    LiveMeetingSession.meterFollowsMicrophone(state) ? SessionMenuRow.allCases : []
  }

  static func showsStatus(state: LiveMeetingSession.SessionState) -> Bool {
    MenuBarSessionPresence.make(state: state, elapsed: 0) != nil
  }
}

/// The popover's live-session section, above the dictation rows.
///
/// A leaf observing the session for the same reason `MenuBarSessionLabel` is
/// one: the popover is open while a session runs, and the clock ticks.
struct SessionMenuSection: View {
  @ObservedObject var session: LiveMeetingSession
  let perform: (MiniIslandAction) -> Void
  /// Same reason as `MenuBarSessionLabel`'s: this popover renders in the Mac's
  /// own appearance, so the ember is resolved against it.
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if SessionMenuRows.showsStatus(state: session.state) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          Circle()
            .fill(
              LiveMeetingSession.meterFollowsMicrophone(session.state)
                ? CraftTokens.ember(colorScheme)
                : Color.secondary
            )
            .frame(width: 7, height: 7)
          Text(MenuBarSessionCopy.status(state: session.state, elapsed: session.elapsed))
            .font(.callout)
        }

        VStack(alignment: .leading, spacing: 1) {
          ForEach(SessionMenuRows.rows(state: session.state), id: \.self) { row in
            Button(row.title) { perform(row.action) }
              .keyboardShortcut(row.action.shortcut)
          }
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(.horizontal, -8)
      }
    }
  }
}
