import SwiftUI
import UniformTypeIdentifiers

// MARK: - History presentation helpers

/// Recency bands and date labels for history lists (the ⌘L drawer): relative
/// dates flatten ordering past a few days ("1mo ago" × 22), so rows outside
/// today get short absolute dates and the list gains band headers.
enum HistoryPresentation {
  enum Band: Int, CaseIterable {
    case today, thisWeek, thisMonth, earlier

    var title: String {
      switch self {
      case .today: return "Today"
      case .thisWeek: return "This Week"
      case .thisMonth: return "This Month"
      case .earlier: return "Earlier"
      }
    }
  }

  static func band(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> Band {
    if calendar.isDate(date, inSameDayAs: now) { return .today }
    if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo {
      return .thisWeek
    }
    if let monthAgo = calendar.date(byAdding: .month, value: -1, to: now), date > monthAgo {
      return .thisMonth
    }
    return .earlier
  }

  /// Short absolute date ("Jun 12", with the year when it differs from now).
  static func shortDate(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d yyyy")
    return formatter.string(from: date)
  }

  /// Source-filename fallback for the generic "Transcript" title: strips the
  /// `.summary` suffix and the trailing `-YYYYMMDD-HHMMSS` stamp, mirroring
  /// how outputs are named (`<base>-<timestamp>.summary.md`).
  static func fallbackTitle(for url: URL) -> String? {
    var base = url.deletingPathExtension().lastPathComponent
    if base.hasSuffix(".summary") {
      base = String(base.dropLast(".summary".count))
    }
    for _ in 0..<2 {
      guard
        let dash = base.range(of: "-", options: .backwards),
        !base[dash.upperBound...].isEmpty,
        base[dash.upperBound...].allSatisfy(\.isNumber)
      else {
        break
      }
      base = String(base[..<dash.lowerBound])
    }
    return base.isEmpty ? nil : base
  }
}

// MARK: - Greeting (B4: date eyebrow + the single serif line)

/// Pure greeting rules for the home header. E3: first run says
/// "Welcome, <name>." with a "First run" eyebrow; every later state (even a
/// used-then-emptied history) reverts to the time-of-day greeting.
enum HomeGreeting {
  /// "First run" for the true first run; otherwise the full date.
  static func eyebrow(isFirstRun: Bool, date: Date = Date()) -> String {
    if isFirstRun { return "First run" }
    return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
  }

  /// "Good morning/afternoon/evening/night" by local hour.
  static func timeOfDayPrefix(date: Date = Date(), calendar: Calendar = .current) -> String {
    switch calendar.component(.hour, from: date) {
    case 5..<12: return "Good morning"
    case 12..<17: return "Good afternoon"
    case 17..<22: return "Good evening"
    default: return "Good night"
    }
  }

  /// The non-name half of the greeting line; the name renders italic in the
  /// serif typeface.
  static func prefix(isFirstRun: Bool, date: Date = Date()) -> String {
    isFirstRun ? "Welcome" : timeOfDayPrefix(date: date)
  }
}

// MARK: - Home dashboard

/// B4 "Craft Glass" home: wash ground, date eyebrow + serif greeting, three
/// entry cards, stats strip. History lives in the ⌘L drawer, not here — the
/// Recent section was removed (owner call 2026-08-03) once the drawer covered
/// it. E3: with zero history only the greeting and cards render — the stats
/// strip is absent, never zero-filled.
struct HomeDashboardView: View {
  @ObservedObject var model: NotaModel
  @ObservedObject var usageProvider: UsageStatsProvider
  /// A gated entry card click opens the toolbar health popover instead of
  /// starting (F1, XIA-394). ContentView owns the shared presentation state.
  var onOpenHealthPopover: () -> Void = {}

  @State private var fileCardTargeted = false
  @State private var isUsageSheetPresented = false

  /// "Needs setup — <what>" reason for a card, from the first FAILING check
  /// that gates it. `unverified` never gates (proceed-at-risk); identity is
  /// optional and never blocks. Memo is exempt from the transcription check
  /// (Apple-engine path).
  private func gateReason(for card: EntryCard) -> String? {
    HomeGating.reason(result: model.preflight, card: card)
  }

  /// Marks the first-run welcome as seen once any content exists; the welcome
  /// itself renders only while nothing has ever been recorded.
  private static let firstRunWelcomeKey = "notaFirstRunWelcomeShown"

  private var isFirstRun: Bool {
    let defaults = UserDefaults.standard
    if defaults.bool(forKey: Self.firstRunWelcomeKey) { return false }
    return model.history.isEmpty
  }

  private var userName: String {
    let full = NSFullUserName()
    let firstName = full.split(separator: " ").first.map(String.init) ?? ""
    return firstName.isEmpty ? full : firstName
  }

  var body: some View {
    ZStack {
      CraftWashBackground()

      ScrollView {
        VStack(alignment: .leading, spacing: CraftTokens.spacing32) {
          greetingHeader
          cardsRow

          // E3: the strip renders only when content exists.
          if !model.history.isEmpty {
            statsStrip
          }
        }
        .padding(CraftTokens.spacing32)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .onAppear {
      if !model.history.isEmpty {
        UserDefaults.standard.set(true, forKey: Self.firstRunWelcomeKey)
      }
      usageProvider.refreshHomeStats()
    }
    .onChange(of: model.history) { _, _ in
      // A run completed (or a row was deleted): refresh the strip figures.
      usageProvider.refreshHomeStats()
      if !model.history.isEmpty {
        UserDefaults.standard.set(true, forKey: Self.firstRunWelcomeKey)
      }
    }
    .sheet(isPresented: $isUsageSheetPresented) {
      // Money is one click away, never ambient (XIA-394).
      UsageSheetView(usageProvider: usageProvider)
    }
  }

  // MARK: - Greeting header

  private var greetingHeader: some View {
    VStack(alignment: .leading, spacing: CraftTokens.spacing8) {
      Text(HomeGreeting.eyebrow(isFirstRun: isFirstRun))
        .font(CraftTokens.metadataFont)
        .foregroundStyle(.secondary)

      (Text(HomeGreeting.prefix(isFirstRun: isFirstRun) + ", ")
        + Text(userName).italic())
        .font(CraftTokens.greetingFont)
        .foregroundStyle(.primary)
    }
    .padding(.top, CraftTokens.spacing8)
  }

  // MARK: - Entry cards (B4: three equal verbs)

  private var cardsRow: some View {
    HStack(spacing: CraftTokens.spacing16) {
      meetingCard
      fileCard
      memoCard
    }
    .frame(maxHeight: 148)
  }

  private var meetingCard: some View {
    let gate = gateReason(for: .meeting)
    return Button {
      if gate == nil {
        model.startLiveSession()
      } else {
        onOpenHealthPopover()
      }
    } label: {
      cardContent(
        icon: "mic.fill",
        title: "Start Meeting",
        subtitle: gate.map { "Needs setup — \($0)" } ?? "Record and transcribe in real time",
        shortcut: "⌘N",
        foreground: gate == nil ? .white : .white.opacity(0.55),
        secondary: .white.opacity(gate == nil ? 0.85 : 0.45)
      )
      .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
      .padding(20)
      .craftPrimaryCard(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .opacity(gate == nil ? 1 : 0.75)
    }
    .buttonStyle(.plain)
    .disabled(model.isRunning)
    .help(gate.map { "Needs setup — \($0)" } ?? "Start a live meeting (⌘N)")
  }

  private var fileCard: some View {
    let gate = gateReason(for: .file)
    return Button {
      if gate == nil {
        model.chooseFile()
      } else {
        onOpenHealthPopover()
      }
    } label: {
      cardContent(
        icon: "arrow.down.doc",
        title: "Transcribe File",
        subtitle: gate.map { "Needs setup — \($0)" } ?? "Drop audio anywhere in the window",
        shortcut: "⌘O",
        foreground: gate == nil ? .primary : .primary.opacity(0.5),
        secondary: .secondary.opacity(gate == nil ? 1 : 0.5)
      )
      .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
      .padding(20)
      .craftDashedDropCard(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(CraftTokens.dropStrokeColor, lineWidth: 2)
          .opacity(fileCardTargeted ? 1 : 0)
      )
      .opacity(gate == nil ? 1 : 0.75)
    }
    .buttonStyle(.plain)
    .disabled(model.isRunning)
    .help(gate.map { "Needs setup — \($0)" } ?? "Transcribe an audio file (⌘O)")
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $fileCardTargeted) { providers in
      // Drops stay live even when the transcription key is missing: the
      // accept path surfaces its own error; the card click explains setup.
      Self.handleDrop(providers: providers, model: model)
    }
  }

  private var memoCard: some View {
    let gate = gateReason(for: .memo)
    return Button {
      if gate == nil {
        model.startLiveSession(kind: .memo)
      } else {
        onOpenHealthPopover()
      }
    } label: {
      cardContent(
        icon: "note.text",
        title: "Quick Memo",
        subtitle: gate.map { "Needs setup — \($0)" } ?? "Speak a note; get a cleaned write-up",
        shortcut: "⌘M",
        foreground: gate == nil ? .primary : .primary.opacity(0.5),
        secondary: .secondary.opacity(gate == nil ? 1 : 0.5)
      )
      .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
      .padding(20)
      .craftGlassPanel(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .opacity(gate == nil ? 1 : 0.75)
    }
    .buttonStyle(.plain)
    .disabled(model.isRunning)
    .help(gate.map { "Needs setup — \($0)" } ?? "Start a quick memo (⌘M)")
  }

  private func cardContent(
    icon: String,
    title: String,
    subtitle: String,
    shortcut: String,
    foreground: Color,
    secondary: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: CraftTokens.spacing12) {
      Image(systemName: icon)
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(foreground)

      Spacer(minLength: 0)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(foreground)

        Text(subtitle)
          .font(.system(size: 12))
          .foregroundStyle(secondary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }

      Text(shortcut)
        .font(CraftTokens.shortcutFont)
        .foregroundStyle(secondary)
    }
  }

  /// Shared drop handler for the file card and the whole window (drop starts
  /// transcription with no dialog — MacWhisper convention, XIA-390 #3).
  static func handleDrop(
    providers: [NSItemProvider],
    model: NotaModel
  ) -> Bool {
    guard let provider = providers.first else { return false }
    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
      let url: URL?
      if let data = item as? Data {
        url = URL(dataRepresentation: data, relativeTo: nil)
      } else if let nsURL = item as? NSURL {
        url = nsURL as URL
      } else {
        url = nil
      }
      if let url {
        Task { @MainActor in model.accept(url) }
      }
    }
    return true
  }

  // MARK: - Stats strip

  private var statsStrip: some View {
    let stats = usageProvider.homeStats
    return Button {
      isUsageSheetPresented = true
    } label: {
      // No dividers between cells (owner call 2026-08-03: the hairlines read
      // as an artifact, not structure) — the equal-width columns are the grid.
      HStack(spacing: CraftTokens.spacing16) {
        statCell(value: Self.minutesText(stats.transcribedMinutes), label: "transcribed this week")
        statCell(value: "\(stats.meetings)", label: stats.meetings == 1 ? "meeting" : "meetings")
        statCell(value: "\(stats.memos)", label: stats.memos == 1 ? "memo" : "memos")
        statCell(value: "\(stats.actionItems)", label: stats.actionItems == 1 ? "action item" : "action items")
      }
      .padding(.horizontal, CraftTokens.spacing24)
      .padding(.vertical, CraftTokens.spacing16)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .craftGlassPanel(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .onHover { hovering in
      // Subtle affordance that the strip opens the Usage sheet.
      if hovering {
        NSCursor.pointingHand.set()
      } else {
        NSCursor.arrow.set()
      }
    }
    .help("Open usage and cost (one click away)")
  }

  private func statCell(value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.system(size: 24, weight: .semibold).monospacedDigit())
        .foregroundStyle(.primary)
      Text(label)
        .font(CraftTokens.metadataFont)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// "45m" under an hour, "1h 05m" beyond.
  static func minutesText(_ minutes: Int) -> String {
    if minutes >= 60 {
      return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
    return "\(minutes)m"
  }

}

#if DEBUG
#Preview("home populated") {
  HomeDashboardView(
    model: NotaModel(),
    usageProvider: UsageStatsProvider(
      projectDirectory: URL(fileURLWithPath: "/Users/xiafawu/Developer/Nota")
    )
  )
  .frame(width: 900, height: 700)
}
#endif
