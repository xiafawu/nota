#if DEBUG
import Foundation

struct TuningSnapshotData: Codable {
  var statusPillH: Double
  var statusPillV: Double
  var statusHStackSpacing: Double
  var toolbarStatusTintOpacity: Double

  var newButtonH: Double
  var newButtonV: Double
  var newButtonStackSpacing: Double
  var primaryActionCornerRadius: Double
  var primaryActionTintOpacity: Double

  var dropCornerRadius: Double
  var dropTargetStrokeWidth: Double
  var dropStrokeIdle: Double
  var dropStrokeActive: Double

  var emptyMainSpacing: Double
  var emptyMainOuterPadding: Double
  var emptyTextSpacing: Double
  var emptySubtextHorizontalPadding: Double

  @MainActor
  init(from store: TuningStore) {
    self.statusPillH = Double(store.statusPillH)
    self.statusPillV = Double(store.statusPillV)
    self.statusHStackSpacing = Double(store.statusHStackSpacing)
    self.toolbarStatusTintOpacity = store.toolbarStatusTintOpacity

    self.newButtonH = Double(store.newButtonH)
    self.newButtonV = Double(store.newButtonV)
    self.newButtonStackSpacing = Double(store.newButtonStackSpacing)
    self.primaryActionCornerRadius = Double(store.primaryActionCornerRadius)
    self.primaryActionTintOpacity = store.primaryActionTintOpacity

    self.dropCornerRadius = Double(store.dropCornerRadius)
    self.dropTargetStrokeWidth = Double(store.dropTargetStrokeWidth)
    self.dropStrokeIdle = Double(store.dropStrokeIdle)
    self.dropStrokeActive = Double(store.dropStrokeActive)

    self.emptyMainSpacing = Double(store.emptyMainSpacing)
    self.emptyMainOuterPadding = Double(store.emptyMainOuterPadding)
    self.emptyTextSpacing = Double(store.emptyTextSpacing)
    self.emptySubtextHorizontalPadding = Double(store.emptySubtextHorizontalPadding)
  }

  @MainActor
  func apply(to store: TuningStore) {
    store.statusPillH = CGFloat(statusPillH)
    store.statusPillV = CGFloat(statusPillV)
    store.statusHStackSpacing = CGFloat(statusHStackSpacing)
    store.toolbarStatusTintOpacity = toolbarStatusTintOpacity

    store.newButtonH = CGFloat(newButtonH)
    store.newButtonV = CGFloat(newButtonV)
    store.newButtonStackSpacing = CGFloat(newButtonStackSpacing)
    store.primaryActionCornerRadius = CGFloat(primaryActionCornerRadius)
    store.primaryActionTintOpacity = primaryActionTintOpacity

    store.dropCornerRadius = CGFloat(dropCornerRadius)
    store.dropTargetStrokeWidth = CGFloat(dropTargetStrokeWidth)
    store.dropStrokeIdle = CGFloat(dropStrokeIdle)
    store.dropStrokeActive = CGFloat(dropStrokeActive)

    store.emptyMainSpacing = CGFloat(emptyMainSpacing)
    store.emptyMainOuterPadding = CGFloat(emptyMainOuterPadding)
    store.emptyTextSpacing = CGFloat(emptyTextSpacing)
    store.emptySubtextHorizontalPadding = CGFloat(emptySubtextHorizontalPadding)
  }
}

@MainActor
final class TuningSnapshotStore: ObservableObject {
  static let shared = TuningSnapshotStore()

  @Published private(set) var snapshots: [String] = []

  private let directory: URL

  init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".nota", isDirectory: true)
      .appendingPathComponent("ui-snapshots", isDirectory: true)
    refresh()
  }

  func refresh() {
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    snapshots = contents
      .filter { $0.pathExtension == "json" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted()
  }

  func save(name: String, from store: TuningStore) throws {
    let safeName = name.replacingOccurrences(of: "/", with: "-")
    let url = directory.appendingPathComponent("\(safeName).json")
    let data = TuningSnapshotData(from: store)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(data).write(to: url, options: .atomic)
    refresh()
  }

  func load(name: String) throws -> TuningSnapshotData {
    let url = directory.appendingPathComponent("\(name).json")
    let bytes = try Data(contentsOf: url)
    return try JSONDecoder().decode(TuningSnapshotData.self, from: bytes)
  }

  func delete(name: String) throws {
    let url = directory.appendingPathComponent("\(name).json")
    try FileManager.default.removeItem(at: url)
    refresh()
  }
}
#endif
