import SwiftUI

/// The drawer row's progress line, and the menu bar's warm slot (XIA-435).
///
/// Both are the same claim rendered twice: a named stage plus how long ago it
/// last moved. Neither draws a percentage — see `ProcessingFreshness` for why
/// a bar would be a lie about a model call, and why a stamp that stops
/// advancing is the only thing that reveals a stuck pipeline.
///
/// The row half attaches with **one modifier call** at the row's call site in
/// `HistoryDrawerView`, so this lane and the context-menu lane can both touch
/// that file in one line each.

// MARK: - Row accessory

/// The status line under a drawer row's title while its record is still being
/// worked on (or has failed with something the owner can do about it).
struct ProcessingRowLine: View {
  let status: ProcessingRowStatus
  let onRetry: (() -> Void)?

  var body: some View {
    HStack(spacing: 6) {
      Text(status.text)
        .font(.caption2)
        .foregroundStyle(status.tone == .failure ? CraftTokens.failure : Color.secondary)
        .lineLimit(1)
        .truncationMode(.tail)

      if status.retry == .summary, let onRetry {
        // Retry is manual, everywhere (standing rule 4). Nothing on this path
        // ever re-runs a summary on its own — an automatic retry spends the
        // owner's money twice without asking.
        Button("Retry summary", action: onRetry)
          .font(.caption2)
          .buttonStyle(.plain)
          .foregroundStyle(Color.accentColor)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

/// Everything a row needs to draw its own progress, in one value.
///
/// Two sources, and the split is deliberate. While a record is **in flight**
/// the answer comes from the ledger, because only the ledger knows when the
/// stage last moved and only it ticks — that is what makes the stamp advance.
/// Once the record is at rest the answer comes from the **record on disk**,
/// which is what survives a relaunch: an interrupted summary still reads
/// "Interrupted · transcript saved" with its Retry the next morning, because
/// the launch sweep wrote that into the record and nothing in memory is
/// involved.
struct ProcessingRowSource {
  /// The row's `.summary.md` path — the join between rows (output directory)
  /// and records (history directory).
  let outputPath: String
  /// The record's persisted status, used once nothing is in flight for it.
  let persistedStatus: HistoryStatus?
  let persistedInterrupted: Bool
  /// Manual retry of the summary stage only. Never called by anything but a
  /// press.
  let onRetrySummary: () -> Void
}

/// The accessory observes the ledger **itself**, so the host view gains one
/// modifier call and no new `@ObservedObject`. The ledger's per-second tick is
/// what redraws the stamp; without observing it here, `HistoryDrawerView` would
/// have to hold the ledger and this lane would own more of that file than one
/// line.
private struct ProcessingRowAccessory: ViewModifier {
  let source: ProcessingRowSource
  @ObservedObject private var ledger = ProcessingLedger.shared

  init(source: ProcessingRowSource) {
    self.source = source
  }

  private var status: ProcessingRowStatus? {
    if let job = ledger.job(outputPath: source.outputPath) {
      return ProcessingRowStatus.make(job: job, now: ledger.tick)
    }
    guard let persisted = source.persistedStatus else { return nil }
    return ProcessingRowStatus.make(
      status: persisted,
      interrupted: source.persistedInterrupted,
      // A record at rest shows no stamp, so the date is never read. Passing
      // `now` for both keeps that a fact rather than a coincidence.
      updatedAt: ledger.tick,
      now: ledger.tick
    )
  }

  func body(content: Content) -> some View {
    if let status {
      VStack(alignment: .leading, spacing: 2) {
        content
        ProcessingRowLine(status: status, onRetry: source.onRetrySummary)
          .padding(.horizontal, 10)
          .padding(.bottom, 4)
      }
    } else {
      content
    }
  }
}

extension View {
  /// Attach a record's progress/failure line under a history row. A record
  /// with nothing to say renders exactly as it did before this lane existed.
  func processingStatus(_ source: ProcessingRowSource) -> some View {
    modifier(ProcessingRowAccessory(source: source))
  }
}

// MARK: - Menu bar

/// The menu bar's slot, kept warm after the ember dot goes out.
///
/// While a session records, the recording surfaces carry the ember (XIA-431).
/// When it stops, the work does not: the record is still being transcribed and
/// summarized somewhere with no window necessarily open, so the status item
/// keeps showing the stage until the record lands. Deliberately **not** ember —
/// the accent is confined to recording surfaces (standing rule 6), and this is
/// what happens after recording is over.
struct ProcessingMenuBarLabel: View {
  @ObservedObject var ledger: ProcessingLedger

  var body: some View {
    if let stage = ProcessingMenuBar.stageText(inFlight: ledger.inFlight) {
      // The stage is SHOWN, not just described. It sat in `.help()` and the
      // accessibility label alone, which meant the acceptance item — "the menu
      // bar item shows the stage" — was met only for a pointer that hovered
      // and a screen reader. The glyph says something is happening; the word
      // says what, which is the whole reason the slot stays warm.
      HStack(spacing: 3) {
        Image(systemName: "arrow.triangle.2.circlepath")
        Text(stage)
          .font(.caption)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Nota: \(stage)")
      .help(stage)
    }
  }
}

/// The MenuBarExtra label: dictation's own status glyph, plus the warm slot
/// while records are processing. Composed here so `NotaApp` gains one line
/// rather than a branch.
struct NotaMenuBarLabel: View {
  @ObservedObject var controller: DictationController
  @ObservedObject var ledger: ProcessingLedger
  /// A plain `let`, deliberately not `@ObservedObject`: the bar item would
  /// otherwise re-render on every change the model publishes, and the only thing
  /// here that is a function of a live session is `MenuBarSessionLabel`, which
  /// observes the session itself as a leaf (XIA-432's rule, one surface further
  /// out).
  let model: NotaModel
  /// Started here rather than in `NotaApp.init`, because this is the view that
  /// exists for the whole life of the process — the document window can be
  /// closed, the status item cannot. `start(model:)` is idempotent, which is
  /// what makes an `onAppear` a legal place to do it (the precedent is
  /// `DictationStatusLabel`'s `controller.start()`).
  let island: MiniRecorderIslandController

  var body: some View {
    HStack(spacing: 3) {
      DictationStatusLabel(controller: controller)
      // XIA-434: the ember dot and the elapsed clock go IN THE BAR, because the
      // status item is the one thing visible in every app and on every Space.
      MenuBarSessionLabel(session: model.liveSession)
      ProcessingMenuBarLabel(ledger: ledger)
    }
    .onAppear { island.start(model: model) }
  }
}
