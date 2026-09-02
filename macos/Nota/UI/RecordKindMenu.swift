import SwiftUI

/// **Change Kind**, in the drawer row's existing context menu (XIA-429 rule 3).
///
/// A kind is decided at record time by which button was pressed, and it is
/// wrong often enough to need a fix — a memo that turned into a meeting, a
/// meeting started from the memo affordance. The fix belongs where every other
/// per-record verb already is: the row's context menu, beside **Reveal in
/// Finder**, **Delete Audio…** and **Delete Record…**.
///
/// It is a **view builder rather than a second `ViewModifier`**, and that is not
/// a style choice: two `.contextMenu` modifiers on one view do not merge — the
/// later one replaces the earlier — so a separate modifier for this lane would
/// have silently taken the two deletion verbs off the row. So the items are
/// built here, in this lane's own file, and `RecordingDeletionMenu` places them
/// in the one menu the row has.
///
/// Three things it owes, and each of them is a rejected alternative:
///
/// - **It never re-summarizes.** Relabeling writes the record and sets
///   `summaryOutdated`; the existing one-click "Regenerate Summary" banner is
///   the path, and the existing `enrichmentNeedsConfirm` alert guards a summary
///   the owner has edited. Spending a model call automatically on a mis-click
///   in a context menu is the failure mode that ruled the alternative out.
/// - **It is a submenu, not three flat items.** Three sibling verbs in a menu
///   whose other entries delete things read as three more deletions; a submenu
///   named for what it changes reads as one verb with an argument.
/// - **The current kind is checked and disabled.** Choosing the kind a record
///   already has would set `summaryOutdated` for a write that changed nothing —
///   a stale banner earned by a no-op.
struct RecordKindMenuItems: View {
  /// The kind the record currently claims. Taken from the row's own detail
  /// rather than re-derived here, so the checkmark and the row's kind chip
  /// cannot disagree.
  let currentKind: HistoryKind
  /// False while this record has work in flight. A relabel is a
  /// read-modify-write of the whole record JSON and `nota history summarize`
  /// writes the same file from another process, so offering it during the exact
  /// window Stop creates is offering to erase a summary that lands mid-write.
  var isBusy: Bool = false
  let onChangeKind: (HistoryKind) -> Void

  /// The order the submenu offers, and the only kinds a *person* may choose.
  /// All three are offerable: a transcribed file that was really a meeting is
  /// exactly the relabel this verb exists for.
  static let choices: [HistoryKind] = [.meeting, .memo, .file]

  /// Whether one row of the submenu may be pressed. Pure, and consumed by the
  /// view below, because "it refuses the kind the record already has" is the
  /// promise and a `.disabled` modifier is unreachable from a test bundle that
  /// gets no accessibility tree.
  static func isEnabled(_ kind: HistoryKind, current: HistoryKind, isBusy: Bool) -> Bool {
    !isBusy && kind != current
  }

  var body: some View {
    Menu(RecordKindCopy.menuTitle) {
      ForEach(Self.choices, id: \.rawValue) { kind in
        Button {
          onChangeKind(kind)
        } label: {
          if kind == currentKind {
            // Drawn rather than described: a menu that only disabled the
            // current row would say "unavailable" where it means "this is what
            // it already is".
            Label(RecordFactsCopy.kind(kind), systemImage: "checkmark")
          } else {
            Text(RecordFactsCopy.kind(kind))
          }
        }
        .disabled(!Self.isEnabled(kind, current: currentKind, isBusy: isBusy))
      }
    }
  }
}

enum RecordKindCopy {
  static let menuTitle = "Change Kind"
  /// What the relabel costs, said once. The banner it refers to is the app's
  /// existing "Regenerate Summary" one — this verb adds no second path.
  static let outdatedNote = "The summary is marked outdated; regenerating is yours to do."
}
