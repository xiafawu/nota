import AppKit
import SwiftUI

// MARK: - What a finished record is, as facts

/// The facts a finished record can state about itself, in **one** value.
///
/// This type exists because the same facts are drawn twice and must not drift
/// (XIA-429, option B). At Stop they rise as a **receipt** in the capsule
/// cluster's footprint — the moment; forever after they are a dot-separated
/// **fact strip** under the document header — the document. One model, two
/// renderings: neither view owns a fact list, neither owns a formatter, and
/// neither can invent a field the other does not have.
///
/// The speaker **chips** are not in here. They stay exactly where they are, in
/// the header; the strip carries the speaker *count* only, because a count is a
/// fact about the recording and a chip is a control that renames a person.
struct RecordFacts: Equatable {
  /// Wall-clock length of the recording. Rendered through
  /// `LiveMeetingFormat.duration` — there is one clock in this app.
  var duration: TimeInterval?
  var kind: HistoryKind?
  var speakerCount: Int?
  var momentCount: Int?
  /// Bytes of kept audio. Nil means **audio not kept** (legacy record, or the
  /// owner deleted it), which is why the field is dropped entirely rather than
  /// rendered `0 B` — a zero would mean a recording that exists and is empty.
  var audioBytes: Int?
  var cost: Cost = .absent

  /// What a record's own money looks like. Four answers, and only one of them
  /// is a number.
  ///
  /// - `.absent` — nothing has been billed to this record (a transcript-only
  ///   live session). The field is not drawn at all.
  /// - `.pending` — a summary is in flight, so a figure is *coming*. This is
  ///   the state that draws a dimmed placeholder at its final width, so the
  ///   receipt does not reflow when the number lands.
  /// - `.known` — a figure, formatted exactly as the Usage sheet formats one.
  /// - `.note` — a model that stores no pricing ("included w/ subscription",
  ///   "refer to OpenRouter"). Never rendered as `$0.00`.
  enum Cost: Equatable {
    case absent
    case pending
    case known(Double)
    case note(String)
  }

  static let empty = RecordFacts()
}

// MARK: - The fields, in order

/// One fact's slot. The order here is the order **both** renderings draw, and
/// the widths here are what a not-yet-known fact reserves.
enum RecordFactField: String, CaseIterable {
  case duration, kind, speakers, moments, audio, cost

  /// The widest string this field can ever hold. A placeholder is drawn at this
  /// width so nothing reflows when the real value arrives (XIA-429 rule 5).
  ///
  /// `hh:mm:ss` for duration for the same reason `SessionTimerMetrics.plateWidth`
  /// reserves it: the step may happen only once.
  /// Whether this field can ever be **pending** — i.e. absent now with a value
  /// coming. Only the cost can: everything else about a finished recording is
  /// known the moment the transcript is sealed.
  ///
  /// The receipt reserves a can-be-pending field at its widest **whether or not
  /// it has landed**, which is the only reading of "final width" that actually
  /// stops a reflow: what finally arrives is either `$0.0031` or "included w/
  /// subscription", and reserving the narrow one would move everything beside
  /// it when the wide one landed.
  var canBePending: Bool { self == .cost }

  var widestPlaceholder: String {
    switch self {
    case .duration: return "88:88:88"
    case .kind: return "Meeting"
    case .speakers: return "88 speakers"
    case .moments: return "88 moments"
    case .audio: return "888.8 MB"
    case .cost: return "included w/ subscription"
    }
  }
}

/// One drawn fact: what field it is, what it says, and how wide its slot is.
///
/// `text == nil` is the **pending** case — the fact is coming and its slot is
/// already the right size. A fact that is simply absent produces no item at
/// all, so a strip never carries an empty gap.
struct RecordFactItem: Identifiable, Equatable {
  let field: RecordFactField
  let text: String?
  let width: CGFloat

  var id: String { field.rawValue }
  var isPending: Bool { text == nil }

  /// The slot the **receipt** gives this fact. Equal to `width` for a fact that
  /// cannot be pending, and the field's widest for one that can — so the same
  /// receipt is the same size before and after the figure arrives.
  ///
  /// The fact **strip** ignores this: a finished document has nothing pending,
  /// and a permanently padded gap in a dot-separated row would be a reservation
  /// for something that is never coming.
  var reservedWidth: CGFloat {
    field.canBePending ? RecordFacts.placeholderWidth(field) : width
  }
}

extension RecordFacts {
  /// The measuring font. One size for both renderings — the receipt and the
  /// strip say the same words in the same face, which is most of what makes
  /// them read as the same claim.
  static let factFontSize: CGFloat = 12
  static var factMeasuringFont: NSFont { .systemFont(ofSize: factFontSize) }

  /// What a field's slot measures. Pure arithmetic over a font, so a test can
  /// answer "does the placeholder reserve the final width" with no window.
  static func width(of text: String) -> CGFloat {
    (text as NSString)
      .size(withAttributes: [.font: factMeasuringFont])
      .width
      .rounded(.up)
  }

  static func placeholderWidth(_ field: RecordFactField) -> CGFloat {
    width(of: field.widestPlaceholder)
  }

  /// What this field says right now, or nil when it has nothing to say.
  /// `.some(nil)` is impossible here — a pending field answers through
  /// `items`, which is the only place the two "no text" cases are told apart.
  func text(for field: RecordFactField) -> String? {
    switch field {
    case .duration:
      guard let duration else { return nil }
      return LiveMeetingFormat.duration(duration)
    case .kind:
      guard let kind else { return nil }
      return RecordFactsCopy.kind(kind)
    case .speakers:
      guard let speakerCount, speakerCount > 0 else { return nil }
      return RecordFactsCopy.count(speakerCount, one: "speaker", many: "speakers")
    case .moments:
      guard let momentCount, momentCount > 0 else { return nil }
      return RecordFactsCopy.count(momentCount, one: "moment", many: "moments")
    case .audio:
      guard let audioBytes else { return nil }
      return StorageFormat.bytes(audioBytes)
    case .cost:
      switch cost {
      case .absent, .pending: return nil
      case .known(let usd): return CostCardViewModel.formatUSD(usd)
      case .note(let note): return note
      }
    }
  }

  /// True when this field has no value yet **and one is coming**. Only cost can
  /// be pending: everything else about a finished recording is known the moment
  /// the transcript is sealed.
  func isPending(_ field: RecordFactField) -> Bool {
    field == .cost && cost == .pending
  }

  /// The ordered facts, as both renderings draw them. A field with nothing to
  /// say and nothing coming is omitted entirely.
  var items: [RecordFactItem] {
    RecordFactField.allCases.compactMap { field in
      if let text = text(for: field) {
        return RecordFactItem(field: field, text: text, width: Self.width(of: text))
      }
      if isPending(field) {
        return RecordFactItem(field: field, text: nil, width: Self.placeholderWidth(field))
      }
      return nil
    }
  }

  /// The facts the **strip** draws: `items`, less anything still pending.
  ///
  /// A dotted separator with a dimmed hole after it is a receipt's job — the
  /// receipt is the surface that has promised not to reflow. A header row that
  /// carried a pending item would draw a dangling `·` and an empty slot for the
  /// whole of a summary run, which is exactly the empty gap the comment on
  /// `RecordFactItem` says a strip may not have. This is the list the view
  /// walks, so the promise is kept by construction rather than by the doc.
  var stripItems: [RecordFactItem] {
    items.filter { !$0.isPending }
  }

  /// The strip, as one string — the concatenation of exactly what the view
  /// draws, separator included.
  var stripText: String {
    stripItems.compactMap(\.text).joined(separator: " · ")
  }

  var isEmpty: Bool { items.isEmpty }

  /// What a record's cost looks like **while work is still running on it**.
  ///
  /// Pure, and separate from the record scan, because it is the one fact whose
  /// display depends on something outside the record: whether a billed call is
  /// in flight right now.
  ///
  /// - Nothing billed yet and a job running → `.pending`, which is what
  ///   reserves the slot at its final width.
  /// - A figure already on the record and a job running → the figure with a
  ///   **`+`**, the same "at least" the CLI's totals line carries. Stating a
  ///   settled `$0.0031` while a second billed model call is running is the
  ///   "quietly understates the bill" failure `recordCost` may not have — and
  ///   it is reachable: Retry summary on a record that already has usage.
  /// - Anything else is left exactly as the record says it.
  static func cost(recorded: Cost, workInFlight: Bool) -> Cost {
    guard workInFlight else { return recorded }
    switch recorded {
    case .absent: return .pending
    case .known(let usd): return .note(CostCardViewModel.formatUSD(usd) + "+")
    case .pending, .note: return recorded
    }
  }
}

/// Every word either rendering can put on screen, in one place.
enum RecordFactsCopy {
  static func kind(_ kind: HistoryKind) -> String {
    switch kind {
    case .meeting: return "Meeting"
    case .memo: return "Memo"
    case .file: return "File"
    }
  }

  /// "1 speaker" / "4 speakers". Singular is not a rounding detail on a surface
  /// whose whole job is to be read once and believed.
  static func count(_ value: Int, one: String, many: String) -> String {
    "\(value) \(value == 1 ? one : many)"
  }

  static let momentsAccessibilityHint = "Scroll to the next flagged moment"

  /// What the receipt *is*, for anyone who cannot see it. Not "Recording
  /// finished": the receipt is up whenever the open document's record has work
  /// in flight, which a Retry on an old record also produces.
  static let receiptLabel = "Record facts"
}

// MARK: - The permanent rendering: the fact strip

/// The dot-separated row under the document header's title and speaker chips.
///
/// It draws `RecordFacts.items` — the same list, in the same order, with the
/// same words the receipt used at Stop. The **moments** item is a button that
/// scrolls the transcript to the next marker pip, which is what keeps the marks
/// enumerable now that nothing lists them (XIA-429 rule 4: pips in the gutter,
/// no timeline, no list, no popover).
struct RecordFactStripView: View {
  let facts: RecordFacts
  /// Advance to the next moment pip. Nil when the document has no pips to
  /// reach (an imported `.md`, or a record with no markers) — the item then
  /// draws as plain text like every other fact.
  var onNextMoment: (() -> Void)?

  /// Exactly the strings this view puts on screen, in order — separators
  /// excluded. A pure function the `body` below literally walks, so a test can
  /// compare the two renderings' *drawn* words rather than a string neither of
  /// them calls.
  static func drawnItems(_ facts: RecordFacts) -> [RecordFactItem] {
    facts.stripItems
  }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(Self.drawnItems(facts).enumerated()), id: \.element.id) { index, item in
        if index > 0 {
          Text(" · ")
            .font(.system(size: RecordFacts.factFontSize))
            .foregroundStyle(.tertiary)
        }
        factView(item)
      }
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func factView(_ item: RecordFactItem) -> some View {
    if item.field == .moments, let onNextMoment, let text = item.text {
      Button(action: onNextMoment) {
        Text(text)
          .font(.system(size: RecordFacts.factFontSize))
          .underline()
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help(RecordFactsCopy.momentsAccessibilityHint)
      .accessibilityHint(RecordFactsCopy.momentsAccessibilityHint)
    } else {
      Text(item.text ?? "")
        .font(.system(size: RecordFacts.factFontSize))
        .foregroundStyle(.secondary)
    }
  }
}
