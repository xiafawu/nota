import SwiftUI

// MARK: - DictionarySettingsView

/// The custom dictionary as its own Settings tab: add one term at a time, or
/// paste a whole word list. Every mutation goes through `DictionaryStore`, so
/// the `nota dictionary` CLI and this pane are always looking at the same file.
struct DictionarySettingsView: View {
  @StateObject private var dictionary = DictionaryModel()
  @State private var showingImport = false

  var body: some View {
    Form {
      addSection
      termsSection
    }
    .formStyle(.grouped)
    // The CLI (`nota dictionary …`) and auto-learn write the same file, so the
    // list is re-read whenever this pane comes back into view.
    .onAppear { dictionary.refresh() }
    .sheet(isPresented: $showingImport) {
      DictionaryImportSheet { text in
        dictionary.importBulk(text)
      }
    }
  }

  // MARK: - Add

  private var addSection: some View {
    Section {
      HStack(spacing: Metrics.statusHStackSpacing) {
        TextField("Term", text: $dictionary.draftTerm)
          .onSubmit { dictionary.addDraft() }
        TextField("Sounds like (optional)", text: $dictionary.draftSpokenForm)
          .onSubmit { dictionary.addDraft() }
        Button("Add") { dictionary.addDraft() }
          .disabled(!dictionary.canAddDraft)
        Button("Import List…") { showingImport = true }
      }

      if let error = dictionary.lastError {
        Text(error)
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.red)
      }
      if let summary = dictionary.lastImportSummary {
        Text(summary.message)
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Add a Term")
    } footer: {
      VStack(alignment: .leading, spacing: Metrics.tightStackSpacing) {
        footerText("Terms bias recognition, are substituted into the text, and are given to the polish model as the correct spelling.")
        footerText("Starred terms are kept first when the list is capped at \(ContextHints.maxHints) recognition hints.")
      }
    }
  }

  // MARK: - Terms

  private var termsSection: some View {
    Section {
      if dictionary.terms.isEmpty {
        Text("No custom terms yet.")
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
      } else {
        ForEach(dictionary.terms, id: \.term) { term in
          row(term)
        }
      }
    } header: {
      Text(dictionary.terms.isEmpty ? "Terms" : "Terms (\(dictionary.terms.count))")
    } footer: {
      footerText("Stored in ~/.nota/dictionary.json — the same file the `nota dictionary` command reads and writes.")
    }
  }

  private func row(_ term: DictionaryTerm) -> some View {
    HStack(spacing: Metrics.statusHStackSpacing) {
      Button {
        dictionary.toggleStar(term)
      } label: {
        Image(systemName: term.starred ? "star.fill" : "star")
      }
      .buttonStyle(.borderless)
      .help(term.starred ? "Unstar" : "Star — starred terms survive the hint cap")

      VStack(alignment: .leading, spacing: 0) {
        Text(term.term)
        if !term.spokenForms.isEmpty {
          Text("sounds like: " + term.spokenForms.joined(separator: ", "))
            .font(Tokens.settingsCaptionFont)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: Metrics.statusHStackSpacing)

      if term.source != .manual {
        Text(term.source.rawValue)
          .font(Tokens.settingsCaptionFont)
          .foregroundStyle(.secondary)
      }

      Button {
        dictionary.remove(term)
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Remove \(term.term)")
    }
  }

  private func footerText(_ text: String) -> some View {
    Text(text)
      .font(Tokens.settingsCaptionFont)
      .foregroundStyle(.secondary)
  }
}

// MARK: - Import sheet

/// Paste-a-word-list sheet. Parsing is `DictionaryBulkImport`'s job; this only
/// collects the text and hands it over.
private struct DictionaryImportSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var text = ""

  let onImport: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Import Terms")
        .font(.headline)
      Text("One term per line, optionally `term | spoken form`. Existing terms keep their star and gain the spoken forms you paste.")
        .font(Tokens.settingsCaptionFont)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      TextEditor(text: $text)
        .font(.system(.body, design: .monospaced))
        .frame(minWidth: 420, minHeight: 220)
        .border(Color.secondary.opacity(0.3))

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Import") {
          onImport(text)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
  }
}

// MARK: - Bulk import parsing

/// Turns a pasted word list into terms. Pure, so the line-level rules are
/// tested without touching disk; the merge rules stay `DictionaryStore`'s.
enum DictionaryBulkImport {
  struct Parsed {
    var terms: [DictionaryTerm]
    /// Lines that carried something but could not become a term (a leading
    /// `|`, or a tab that the store and the CLI's TSV output both reject).
    /// Counted rather than dropped in silence.
    var skippedLines: Int
  }

  /// Separator between a term and its spoken forms. Repeatable:
  /// `term | form one | form two`.
  static let separator: Character = "|"

  static func parse(_ text: String) -> Parsed {
    var terms: [DictionaryTerm] = []
    var skipped = 0

    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      // Blank lines are structure in a pasted list, not an error.
      guard !trimmed.isEmpty else { continue }

      let fields = trimmed.split(separator: separator, omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      guard let term = fields.first, !term.isEmpty, !term.contains("\t") else {
        skipped += 1
        continue
      }

      // `a || b` and a trailing separator both leave empty fields behind.
      let spokenForms = fields.dropFirst().filter { !$0.isEmpty }
      // Dedupe inside the paste with the very rule the store uses, so a list
      // containing a term twice behaves exactly like adding it twice.
      terms = DictionaryStore.merging(
        DictionaryTerm(term: term, spokenForms: Array(spokenForms)),
        into: terms
      )
    }

    return Parsed(terms: terms, skippedLines: skipped)
  }
}

/// What an import did, as counts the pane can show.
struct DictionaryImportSummary: Equatable {
  var added = 0
  var merged = 0
  var skipped = 0

  var message: String {
    guard added + merged + skipped > 0 else { return "Nothing to import." }
    var parts: [String] = []
    if added > 0 { parts.append("added \(added)") }
    if merged > 0 { parts.append("merged \(merged)") }
    if skipped > 0 { parts.append("skipped \(skipped)") }
    return "Imported: " + parts.joined(separator: ", ") + "."
  }
}

// MARK: - DictionaryModel

/// View state over `DictionaryStore`. Every mutation writes through to
/// `~/.nota/dictionary.json` and re-reads, so the list on screen is always the
/// file on disk rather than a drifting in-memory copy.
@MainActor
final class DictionaryModel: ObservableObject {
  @Published private(set) var terms: [DictionaryTerm] = []
  @Published var draftTerm: String = ""
  @Published var draftSpokenForm: String = ""
  @Published var lastError: String?
  @Published private(set) var lastImportSummary: DictionaryImportSummary?

  init() {
    refresh()
  }

  var canAddDraft: Bool {
    !draftTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func refresh() {
    terms = DictionaryStore.load().sorted {
      $0.term.lowercased() < $1.term.lowercased()
    }
  }

  func addDraft() {
    let term = draftTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return }
    let spoken = draftSpokenForm.trimmingCharacters(in: .whitespacesAndNewlines)
    lastImportSummary = nil
    perform {
      try DictionaryStore.add(term, spokenForms: spoken.isEmpty ? [] : [spoken])
      self.draftTerm = ""
      self.draftSpokenForm = ""
    }
  }

  func remove(_ term: DictionaryTerm) {
    perform { _ = try DictionaryStore.remove(term.term) }
  }

  func toggleStar(_ term: DictionaryTerm) {
    perform { _ = try DictionaryStore.setStarred(!term.starred, for: term.term) }
  }

  /// Import a pasted list. Each entry goes through `DictionaryStore.add`, so
  /// an already-known term is merged (spoken forms unioned, star and original
  /// `addedAt` kept) rather than replaced.
  func importBulk(_ text: String) {
    let parsed = DictionaryBulkImport.parse(text)
    let known = Set(terms.map(\.key))
    var summary = DictionaryImportSummary(skipped: parsed.skippedLines)
    perform {
      for term in parsed.terms {
        try DictionaryStore.add(term.term, spokenForms: term.spokenForms)
        if known.contains(term.key) {
          summary.merged += 1
        } else {
          summary.added += 1
        }
      }
    }
    lastImportSummary = summary
  }

  private func perform(_ mutation: () throws -> Void) {
    do {
      try mutation()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    refresh()
  }
}
