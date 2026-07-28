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
    existing + joiningSeparator(existing, addition) + addition
  }

  /// What `joined` puts between the two runs: one space, or nothing.
  ///
  /// Split out because the prompter draws the halves as two `Text` runs at
  /// different opacities and has to concatenate them with *exactly* the
  /// separator `joined` used to measure them. An unconditional `Text(" ")`
  /// between the runs draws a double space whenever Apple's volatile result
  /// arrives with its leading space already attached — the very case this
  /// function exists to absorb — so the card would draw a string it never
  /// measured.
  static func joiningSeparator(_ existing: String, _ addition: String) -> String {
    guard !existing.isEmpty, !addition.isEmpty else { return "" }
    if existing.last?.isWhitespace == true || addition.first?.isWhitespace == true {
      return ""
    }
    return " "
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
  ///
  /// Sized to the pill's draft block — two `.callout` lines across
  /// `HUDPillMetrics.draftWidth` — so the clamp lands just past what the block
  /// can show rather than well inside it. Overshooting is safe: the block
  /// head-truncates, and the newest words are the ones that survive either cut.
  static let roughDraftLimit = 120

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

  /// One piece of speech on its way to the target, and how it was cut.
  ///
  /// Not every release is a sentence. The 240-char overflow valve cuts a
  /// run-on at its last word boundary, and `Formatter`'s capitalize and
  /// terminal-punctuation rules would dress that fragment up as a sentence —
  /// typing a period into the middle of a phrase the user is still speaking and
  /// capitalizing the word that continues it. Delivery is append-only, so
  /// neither can be taken back.
  struct Segment: Sendable, Equatable {
    let text: String
    /// False when this continues a sentence an earlier fragment opened.
    var startsSentence: Bool = true
    /// False when the valve cut this mid-sentence.
    var endsSentence: Bool = true

    /// True only for a segment that is a sentence on both ends — the only kind
    /// polish is allowed to see.
    var isWholeSentence: Bool { startsSentence && endsSentence }
  }

  /// `Formatter.applyRules` with the two sentence-shaped rules made conditional.
  ///
  /// Whitespace, filler, and false-start cleanup are safe on any run of words;
  /// capitalization and the trailing period are claims about where a sentence
  /// begins and ends, and are applied only where the segmenter actually found
  /// one.
  static func applyRules(to segment: Segment) -> String {
    guard !segment.text.isEmpty else { return segment.text }
    var text = Formatter.normalizeWhitespace(segment.text)
    text = Formatter.dropFillerWords(text)
    text = Formatter.cleanupFalseStarts(text)
    if segment.startsSentence { text = Formatter.capitalizeFirst(text) }
    if segment.endsSentence { text = Formatter.ensureTerminalPunctuation(text) }
    return text
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
  ///
  /// Polish only ever sees a whole sentence. It is a sentence-level rewriter:
  /// hand it the overflow valve's mid-sentence fragment and it hands back a
  /// sentence, capital and full stop included, in text that has already been
  /// promised to a live document.
  static func refine(
    _ segment: Segment,
    terms: [DictionaryTerm],
    polish: (@Sendable (String) async throws -> String)?
  ) async -> RefinedSentence {
    let offline = WordReplacements.apply(applyRules(to: segment), terms: terms)
    guard let polish, !offline.isEmpty, segment.isWholeSentence else {
      return RefinedSentence(text: offline, offline: offline, polishError: nil)
    }
    do {
      return RefinedSentence(text: try await polish(offline), offline: offline, polishError: nil)
    } catch {
      return RefinedSentence(text: offline, offline: offline, polishError: error)
    }
  }

  /// Convenience for text already known to be a whole sentence.
  static func refine(
    _ sentence: String,
    terms: [DictionaryTerm],
    polish: (@Sendable (String) async throws -> String)?
  ) async -> RefinedSentence {
    await refine(Segment(text: sentence), terms: terms, polish: polish)
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

  /// True while the last thing released was a mid-sentence fragment, so
  /// whatever comes next continues it rather than starting a sentence.
  private var isMidSentence = false

  /// Feed newly finalized text; returns the segments it completes, in order.
  mutating func append(_ text: String) -> [StreamingDelivery.Segment] {
    guard !text.isEmpty else { return [] }
    pending = StreamingDelivery.joined(pending, text)
    return drain()
  }

  /// Release everything still held, clearing the segmenter. Called once when
  /// the session stops so the un-finalized tail still reaches the target.
  ///
  /// The tail ends the session, so it ends a sentence: it gets the same
  /// terminal punctuation the batch path would have given it.
  mutating func flush() -> StreamingDelivery.Segment? {
    let remainder = pending.trimmingCharacters(in: .whitespacesAndNewlines)
    pending = ""
    guard !remainder.isEmpty else { return nil }
    let segment = StreamingDelivery.Segment(
      text: remainder,
      startsSentence: !isMidSentence,
      endsSentence: true
    )
    isMidSentence = false
    return segment
  }

  // MARK: - Cutting

  private mutating func drain() -> [StreamingDelivery.Segment] {
    var segments: [StreamingDelivery.Segment] = []

    while let cut = Self.sentenceEnd(in: pending) {
      let sentence = String(pending[pending.startIndex..<cut])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      pending = String(pending[cut...]).trimmingLeadingWhitespace()
      guard !sentence.isEmpty else { continue }
      segments.append(
        StreamingDelivery.Segment(
          text: sentence,
          startsSentence: !isMidSentence,
          endsSentence: true
        )
      )
      isMidSentence = false
    }

    // Overflow release. Cutting at the last space keeps the trailing partial
    // word in `pending`, so a word is never split across two deliveries — but
    // the cut lands mid-sentence, and the segment says so.
    while pending.count > Self.maxPendingCharacters,
          let space = pending.lastIndex(where: { $0.isWhitespace }) {
      let chunk = String(pending[..<space])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      pending = String(pending[pending.index(after: space)...])
      guard !chunk.isEmpty else { continue }
      segments.append(
        StreamingDelivery.Segment(
          text: chunk,
          startsSentence: !isMidSentence,
          endsSentence: false
        )
      )
      isMidSentence = true
    }

    return segments
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
  /// Cleanup + dictionary + polish for one segment. Never throws: a failed
  /// polish must yield the offline text, not stall the queue.
  typealias Refine = @Sendable (StreamingDelivery.Segment) async -> String
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
  /// Set by `cancel()`. A refinement that had already passed its own
  /// cancellation check must not be able to restart the pump behind it.
  private var isCancelled = false

  init(refine: @escaping Refine, deliver: @escaping Deliver) {
    self.refine = refine
    self.deliver = deliver
  }

  /// Number of sentences accepted this session.
  private(set) var enqueuedCount = 0

  /// Submit a completed segment. Returns immediately; refinement runs
  /// concurrently and delivery is serialized behind every earlier segment.
  func enqueue(_ segment: StreamingDelivery.Segment) {
    guard !isCancelled else { return }
    let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    let unit = StreamingDelivery.Segment(
      text: trimmed,
      startsSentence: segment.startsSentence,
      endsSentence: segment.endsSentence
    )
    let index = nextIndex
    nextIndex += 1
    enqueuedCount += 1

    let refine = self.refine
    refinements.append(Task { [weak self] in
      let refined = await refine(unit)
      guard let self else { return }
      self.complete(index: index, text: refined)
    })
  }

  /// Submit text already known to be a whole sentence.
  func enqueue(_ sentence: String) {
    enqueue(StreamingDelivery.Segment(text: sentence))
  }

  /// Abandon this session's work.
  ///
  /// Refinement outlives the session that started it — a polish call can sit
  /// for its whole timeout — and its completion writes controller state
  /// (polish counters, last-result diagnostics, the auto-learn budget) that by
  /// then belongs to the *next* session. Nothing here may deliver afterwards
  /// either: the target it was captured for is gone.
  func cancel() {
    isCancelled = true
    for task in refinements { task.cancel() }
    refinements = []
    pumpTask?.cancel()
    pumpTask = nil
    queued = []
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
    guard !isCancelled else { return }
    let ready = buffer.complete(index: index, text: text)
    guard !ready.isEmpty else { return }
    queued.append(contentsOf: ready)
    startPumpIfNeeded()
  }

  /// One pump task at a time is what serializes delivery. It exits only with
  /// `queued` observed empty in the same synchronous step that clears
  /// `pumpTask`, so a completion landing mid-drain can never be stranded.
  private func startPumpIfNeeded() {
    guard pumpTask == nil, !isCancelled else { return }
    pumpTask = Task { [weak self] in
      guard let self else { return }
      while !self.isCancelled, !self.queued.isEmpty {
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
