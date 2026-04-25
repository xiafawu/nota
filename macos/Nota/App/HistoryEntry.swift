import Foundation

struct HistoryEntry: Identifiable, Hashable {
  let url: URL
  let modifiedAt: Date

  var id: URL { url }

  var title: String {
    let base = url.deletingPathExtension().lastPathComponent
    let stripped = base.hasSuffix(".summary") ? String(base.dropLast(".summary".count)) : base
    if let dashRange = stripped.range(of: "-", options: .backwards),
       let _ = Int(stripped[dashRange.upperBound...].prefix(8)) {
      let prefix = stripped[..<dashRange.lowerBound]
      if !prefix.isEmpty {
        return String(prefix)
      }
    }
    return stripped
  }

  var relativeDate: String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: modifiedAt, relativeTo: Date())
  }
}
