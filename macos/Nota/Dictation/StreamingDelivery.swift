import Foundation

// MARK: - StreamingDelivery

/// Pure helpers shared by the streaming-delivery path.
///
/// Everything here is deterministic and I/O-free so the invariants that matter
/// — where a sentence ends, what gets appended, what order it arrives in — are
/// testable without a recognizer, a network call, or an Accessibility target.
enum StreamingDelivery {
  /// Join two runs of recognized text with exactly one space.
  ///
  /// Finalized results arrive as deltas and Apple is inconsistent about whether
  /// a delta carries its leading space. Concatenating blind welds words
  /// together ("Hello" + "world."); always inserting a space doubles the ones
  /// that are already there. So: insert one only when neither side has any.
  static func joined(_ existing: String, _ addition: String) -> String {
    guard !existing.isEmpty else { return addition }
    guard !addition.isEmpty else { return existing }
    if existing.last?.isWhitespace == true || addition.first?.isWhitespace == true {
      return existing + addition
    }
    return existing + " " + addition
  }

  /// The exact string to append to the target app so that everything delivered
  /// so far, plus `next`, reads correctly.
  ///
  /// Append-only is the whole contract: this never describes a rewrite of
  /// `previous`, only what comes after it. An empty return means "nothing to
  /// type" and the caller must not touch the target at all.
  static func appendDelta(previous: String, next: String) -> String {
    let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    guard let last = previous.last else { return trimmed }
    return last.isWhitespace ? trimmed : " " + trimmed
  }

  /// Characters of the volatile tail the HUD shows as a rough draft.
  static let roughDraftLimit = 60

  /// The tail of the in-flight recognition, clamped for the HUD line.
  ///
  /// Returns nil when there is nothing to show, so the HUD can omit the line
  /// entirely rather than reserving an empty row that makes the pill jump.
  static func roughDraftTail(_ text: String, limit: Int = roughDraftLimit) -> String? {
    let collapsed = text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !collapsed.isEmpty, limit > 0 else { return nil }
    guard collapsed.count > limit else { return collapsed }
    return "…" + String(collapsed.suffix(limit))
  }

  /// One sentence's trip through the pipeline the batch path runs whole:
  /// `Formatter.applyRules` → `WordReplacements` → polish.
  struct RefinedSentence {
    /// The text to append to the target.
    let text: String
    /// The offline (rules + dictionary) result. `text` is exactly this when
    /// polish is off or failed.
    let offline: String
    /// Non-nil when polish was attempted and threw.
    let polishError: (any Error)?
  }

  /// Refine one finalized sentence.
  ///
  /// Never throws. A polish failure downgrades that sentence to its offline
  /// text and reports the error alongside it — the queue behind this must keep
  /// moving, because the sentences after it are already being spoken.
  ///
  /// `polish` is injected rather than called directly so the fallback is
  /// testable without a network call or an API key.
  static func refine(
    _ sentence: String,
    terms: [DictionaryTerm],
    polish: (@Sendable (String) async throws -> String)?
  ) async -> RefinedSentence {
    let offline = WordReplacements.apply(Formatter.applyRules(sentence), terms: terms)
    guard let polish, !offline.isEmpty else {
      return RefinedSentence(text: offline, offline: offline, polishError: nil)
    }
    do {
      return RefinedSentence(text: try await polish(offline), offline: offline, polishError: nil)
    } catch {
      return RefinedSentence(text: offline, offline: offline, polishError: error)
    }
  }
}

// MARK: - SentenceSegmenter

/// Cuts a growing stream of *finalized* recognition text into whole sentences.
///
/// The recognizer finalizes in its own chunks — sometimes half a sentence,
/// sometimes three at once — but polish only reads well on a complete
/// sentence, and text appended to the target can never be taken back. So
/// finalized text accumulates here and leaves only at a sentence boundary;
/// whatever has not reached one is `pending` until the session ends and
/// `flush()` releases it.
struct SentenceSegmenter {
  /// Finalized text that has not yet completed a sentence.
  private(set) var pending: String = ""

  /// Above this, `pending` is released at its last word boundary even without
  /// a terminator. A speaker who never lands a period would otherwise get
  /// nothing until they stopped — which is the behavior streaming exists to
  /// replace.
  static let maxPendingCharacters = 240

  static let terminators: Set<Character> = [".", "!", "?"]

  /// Marks that may trail a terminator and still belong to the sentence:
  /// `he said "stop."` ends after the quote, not before it.
  private static let trailingMarks: Set<Character> = [
    "\"", "'", ")", "]", "}", "”", "’", "»", "…",
  ]

  /// Words that end in a period without ending a sentence. Not exhaustive and
  /// does not need to be — a missed guard costs one extra delivery boundary,
  /// never a lost or duplicated word.
  static let abbreviations: Set<String> = [
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie",
    "fig", "approx", "inc", "ltd", "dept", "vol", "cf", "al", "no", "pp",
  ]

  /// Feed newly finalized text; returns the sentences it completes, in order.
  mutating func append(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    pending = StreamingDelivery.joined(pending, text)
    return drain()
  }

  /// Release everything still held, clearing the segmenter. Called once when
  /// the session stops so the un-finalized tail still reaches the target.
  mutating func flush() -> String? {
    let remainder = pending.trimmingCharacters(in: .whitespacesAndNewlines)
    pending = ""
    return remainder.isEmpty ? nil : remainder
  }

  // MARK: - Cutting

  private mutating func drain() -> [String] {
    var sentences: [String] = []

    while let cut = Self.sentenceEnd(in: pending) {
      let sentence = String(pending[pending.startIndex..<cut])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      pending = String(pending[cut...]).trimmingLeadingWhitespace()
      if !sentence.isEmpty { sentences.append(sentence) }
    }

    // Overflow release. Cutting at the last space keeps the trailing partial
    // word in `pending`, so a word is never split across two deliveries.
    while pending.count > Self.maxPendingCharacters,
          let space = pending.lastIndex(where: { $0.isWhitespace }) {
      let chunk = String(pending[..<space])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      pending = String(pending[pending.index(after: space)...])
      if !chunk.isEmpty { sentences.append(chunk) }
    }

    return sentences
  }

  /// Index just past the end of the first complete sentence in `text`, or nil.
  ///
  /// A boundary is a terminator (plus any run of terminators and closing
  /// marks) followed by whitespace or the end of the finalized text. End of
  /// text counts because finalized text never changes — waiting for a
  /// following space would hold the last sentence of every pause hostage.
  static func sentenceEnd(in text: String) -> String.Index? {
    var index = text.startIndex
    while index < text.endIndex {
      guard terminators.contains(text[index]) else {
        index = text.index(after: index)
        continue
      }

      var end = text.index(after: index)
      while end < text.endIndex,
            terminators.contains(text[end]) || trailingMarks.contains(text[end]) {
        end = text.index(after: end)
      }

      let followedByBreak = end == text.endIndex || text[end].isWhitespace
      if followedByBreak, !isAbbreviation(endingAt: index, in: text) {
        return end
      }
      index = end
    }
    return nil
  }

  /// Whether the period at `terminator` closes an abbreviation or an initial
  /// rather than a sentence. `!` and `?` are never abbreviations.
  static func isAbbreviation(endingAt terminator: String.Index, in text: String) -> Bool {
    guard text[terminator] == "." else { return false }

    var token = ""
    var index = terminator
    while index > text.startIndex {
      let previous = text.index(before: index)
      let character = text[previous]
      guard character.isLetter || character.isNumber else { break }
      token.insert(character, at: token.startIndex)
      index = previous
    }

    guard !token.isEmpty else { return false }
    // A single character before the dot is an initial ("J. Smith") or a list
    // number ("1. first"), never the last word of a sentence worth cutting on.
    if token.count == 1 { return true }
    return abbreviations.contains(token.lowercased())
  }
}

private extension String {
  func trimmingLeadingWhitespace() -> String {
    guard let start = firstIndex(where: { !$0.isWhitespace }) else { return "" }
    return String(self[start...])
  }
}

// MARK: - OrderedDeliveryBuffer

/// Reorders finished segments back into the order they were spoken.
///
/// Refinement (dictionary + polish) runs concurrently, so segment 2's network
/// call routinely returns before segment 1's. Text is appended to a live
/// document and cannot be reordered afterwards, so a completion out of order
/// is held here until its predecessors land.
struct OrderedDeliveryBuffer {
  private var nextIndex = 0
  private var held: [Int: String] = [:]

  /// Record segment `index`'s finished text; returns everything that is now
  /// deliverable, in order (often empty, occasionally several at once).
  mutating func complete(index: Int, text: String) -> [String] {
    guard index >= nextIndex, held[index] == nil else { return [] }
    held[index] = text

    var ready: [String] = []
    while let next = held.removeValue(forKey: nextIndex) {
      ready.append(next)
      nextIndex += 1
    }
    return ready
  }

  /// True while at least one completion is waiting on an earlier segment.
  var isHoldingSegments: Bool { !held.isEmpty }
}

// MARK: - StreamingDeliveryQueue

/// Drives one dictation session's sentences from recognition to the target
/// app: refine concurrently, deliver strictly in order, append only.
///
/// `refine` and `deliver` are injected so the ordering guarantee can be tested
/// against deliberately out-of-order refinements without an Accessibility
/// target or a network call.
@MainActor
final class StreamingDeliveryQueue {
  /// Cleanup + dictionary + polish for one sentence. Never throws: a failed
  /// polish must yield the offline text, not stall the queue.
  typealias Refine = @Sendable (String) async -> String
  /// Append `delta` to the target app.
  typealias Deliver = @MainActor (String) async -> Void

  private let refine: Refine
  private let deliver: Deliver

  /// Everything handed to `deliver` so far, concatenated. This is the session's
  /// authoritative record of what the target already contains from us — and,
  /// because delivery is append-only, it only ever grows.
  private(set) var deliveredText = ""

  private var nextIndex = 0
  private var buffer = OrderedDeliveryBuffer()
  private var refinements: [Task<Void, Never>] = []
  private var queued: [String] = []
  private var pumpTask: Task<Void, Never>?

  init(refine: @escaping Refine, deliver: @escaping Deliver) {
    self.refine = refine
    self.deliver = deliver
  }

  /// Number of sentences accepted this session.
  private(set) var enqueuedCount = 0

  /// Submit a completed sentence. Returns immediately; refinement runs
  /// concurrently and delivery is serialized behind every earlier sentence.
  func enqueue(_ sentence: String) {
    let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let index = nextIndex
    nextIndex += 1
    enqueuedCount += 1

    let refine = self.refine
    refinements.append(Task { [weak self] in
      let refined = await refine(trimmed)
      guard let self else { return }
      self.complete(index: index, text: refined)
    })
  }

  /// Wait until every submitted sentence has been refined and delivered.
  func finish() async {
    while true {
      let pending = refinements
      refinements = []
      for task in pending { _ = await task.value }
      if let pump = pumpTask { _ = await pump.value }
      if refinements.isEmpty, queued.isEmpty, pumpTask == nil { return }
    }
  }

  // MARK: - Private

  private func complete(index: Int, text: String) {
    let ready = buffer.complete(index: index, text: text)
    guard !ready.isEmpty else { return }
    queued.append(contentsOf: ready)
    startPumpIfNeeded()
  }

  /// One pump task at a time is what serializes delivery. It exits only with
  /// `queued` observed empty in the same synchronous step that clears
  /// `pumpTask`, so a completion landing mid-drain can never be stranded.
  private func startPumpIfNeeded() {
    guard pumpTask == nil else { return }
    pumpTask = Task { [weak self] in
      guard let self else { return }
      while !self.queued.isEmpty {
        let text = self.queued.removeFirst()
        let delta = StreamingDelivery.appendDelta(previous: self.deliveredText, next: text)
        guard !delta.isEmpty else { continue }
        self.deliveredText += delta
        await self.deliver(delta)
      }
      self.pumpTask = nil
    }
  }
}
