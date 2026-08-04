import XCTest
@testable import Nota

// MARK: - Fixtures

private func makeRecord(
  id: String = "rec-1",
  status: String = "transcribed",
  narrative: String? = nil,
  tags: [String]? = nil,
  summaryEdited: Bool? = nil,
  tagsEdited: Bool? = nil,
  outputPath: String? = nil
) -> EnrichmentRecord {
  let summary: EnrichmentSummary? = (narrative != nil || tags != nil)
    ? EnrichmentSummary(title: nil, tags: tags, narrative: narrative, keyTopics: nil, decisions: nil, actionItems: nil)
    : nil
  return EnrichmentRecord(
    id: id,
    status: status,
    summary: summary,
    summaryEdited: summaryEdited,
    tagsEdited: tagsEdited,
    outputPath: outputPath
  )
}

private func recordJSON(
  id: String = "rec-1",
  status: String = "completed",
  narrative: String? = "A generated narrative.",
  tags: [String] = ["planning", "roadmap"],
  summaryEdited: Bool? = nil,
  tagsEdited: Bool? = nil,
  suggestions: [[String: Any]]? = nil,
  summaryOutdated: Bool? = nil
) throws -> Data {
  var summary: [String: Any] = [
    "title": "Team Sync",
    "tags": tags,
    "keyTopics": ["planning"],
    "decisions": [String](),
    "actionItems": [String](),
  ]
  if let narrative {
    summary["narrative"] = narrative
  }
  var record: [String: Any] = [
    "id": id,
    "createdAt": "2026-07-18T10:00:00.000Z",
    "updatedAt": "2026-07-18T10:00:00.000Z",
    "sourcePath": "/tmp/audio.m4a",
    "sourceName": "audio.m4a",
    "provider": "assemblyai",
    "status": status,
    "transcriptText": "hello world",
    "segments": [["start": 0, "end": 1, "text": "hello world"]],
    "summary": summary,
  ]
  if let summaryEdited {
    record["summaryEdited"] = summaryEdited
  }
  if let tagsEdited {
    record["tagsEdited"] = tagsEdited
  }
  if let suggestions {
    record["suggestions"] = suggestions
  }
  if let summaryOutdated {
    record["summaryOutdated"] = summaryOutdated
  }
  return try JSONSerialization.data(withJSONObject: record)
}

/// One pending-suggestion dict in the record's on-disk shape.
private func suggestionJSON(
  label: String = "Speaker 2",
  suggestedName: String = "Kenny Kim",
  score: Double = 0.623,
  voiceprintId: String = "20260717-004104Z",
  state: String = "pending",
  decidedAt: String? = nil
) -> [String: Any] {
  var dict: [String: Any] = [
    "label": label,
    "suggestedName": suggestedName,
    "score": score,
    "voiceprintId": voiceprintId,
    "state": state,
  ]
  if let decidedAt {
    dict["decidedAt"] = decidedAt
  }
  return dict
}

// MARK: - Mock process layer (the CLI contract is mocked; the TS side is
// exercised post-merge, never from these tests)

private final class MockEnrichmentRunner: EnrichmentProcessRunning, @unchecked Sendable {
  var result: Result<Data, Error> = .success(Data())
  private(set) var calls: [(arguments: [String], stdinJSON: Data?)] = []

  func run(arguments: [String], stdinJSON: Data?) async throws -> Data {
    calls.append((arguments, stdinJSON))
    return try result.get()
  }
}

/// Blocks until the surrounding task is cancelled (Cancel-button path).
private final class HangingEnrichmentRunner: EnrichmentProcessRunning, @unchecked Sendable {
  func run(arguments: [String], stdinJSON: Data?) async throws -> Data {
    try await Task.sleep(nanoseconds: 60_000_000_000)
    return Data()
  }
}

// MARK: - Record decode

final class EnrichmentRecordDecodeTests: XCTestCase {
  func testDecode_withEnrichmentFlags() throws {
    let data = try recordJSON(summaryEdited: true, tagsEdited: true)
    let record = try EnrichmentRecord.decode(data)

    XCTAssertEqual(record.id, "rec-1")
    XCTAssertEqual(record.status, "completed")
    XCTAssertEqual(record.summary?.narrative, "A generated narrative.")
    XCTAssertEqual(record.tags, ["planning", "roadmap"])
    XCTAssertTrue(record.isSummaryEdited)
    XCTAssertTrue(record.isTagsEdited)
  }

  func testDecode_withoutFlags_legacyRecordReadsUnedited() throws {
    let data = try recordJSON(summaryEdited: nil, tagsEdited: nil)
    let record = try EnrichmentRecord.decode(data)

    XCTAssertNil(record.summaryEdited)
    XCTAssertNil(record.tagsEdited)
    XCTAssertFalse(record.isSummaryEdited)
    XCTAssertFalse(record.isTagsEdited)
  }

  func testDecode_transcribedRecordWithoutSummary() throws {
    var record: [String: Any] = [
      "id": "rec-2",
      "status": "transcribed",
      "transcriptText": "hello",
    ]
    record["segments"] = [[String: Any]]()
    let data = try JSONSerialization.data(withJSONObject: record)

    let decoded = try EnrichmentRecord.decode(data)

    XCTAssertNil(decoded.summary)
    XCTAssertFalse(decoded.hasSummaryNarrative)
    XCTAssertEqual(decoded.tags, [])
  }

  func testDecode_garbageThrows() {
    XCTAssertThrowsError(try EnrichmentRecord.decode(Data("not json".utf8)))
  }
}

// MARK: - Slot state selection

final class EnrichmentSlotStateTests: XCTestCase {
  func testNilRecord_hidden() {
    XCTAssertEqual(
      enrichmentSlotState(record: nil, activity: .idle, modelID: "m"),
      .hidden
    )
  }

  func testTranscribedNoSummary_placeholder() {
    let record = makeRecord(status: "transcribed")
    XCTAssertEqual(
      enrichmentSlotState(record: record, activity: .idle, modelID: "m"),
      .placeholder
    )
  }

  func testTranscribedTagsOnly_staysPlaceholder() {
    // Tags-only generation does not flip status; the summary slot still
    // offers generation because there is no narrative yet.
    let record = makeRecord(status: "transcribed", tags: ["planning"])
    XCTAssertEqual(
      enrichmentSlotState(record: record, activity: .idle, modelID: "m"),
      .placeholder
    )
  }

  func testCompletedWithNarrative_summary() {
    let record = makeRecord(status: "completed", narrative: "Text.", summaryEdited: true)
    XCTAssertEqual(
      enrichmentSlotState(record: record, activity: .idle, modelID: "m"),
      .summary(narrative: "Text.", edited: true)
    )
  }

  func testEditedBadgeDerivesFromRecordFlagOnly() {
    let record = makeRecord(status: "completed", narrative: "Text.")
    XCTAssertEqual(
      enrichmentSlotState(record: record, activity: .idle, modelID: "m"),
      .summary(narrative: "Text.", edited: false)
    )
  }

  func testGenerating_overridesRecordState() {
    let record = makeRecord(status: "completed", narrative: "Text.")
    XCTAssertEqual(
      enrichmentSlotState(record: record, activity: .summarizing, modelID: "gpt-5-mini"),
      .generating(kind: .summarizing, modelID: "gpt-5-mini")
    )
  }
}

// MARK: - Confirm-required logic (edited-is-protected)

final class EnrichmentConfirmTests: XCTestCase {
  func testSummaryConfirm_onlyWhenSummaryEdited() {
    let edited = makeRecord(narrative: "Text.", summaryEdited: true)
    XCTAssertTrue(enrichmentNeedsConfirm(record: edited, target: .summary))
    XCTAssertFalse(enrichmentNeedsConfirm(record: edited, target: .tags))
  }

  func testTagsConfirm_onlyWhenTagsEdited() {
    let edited = makeRecord(tags: ["manual"], tagsEdited: true)
    XCTAssertTrue(enrichmentNeedsConfirm(record: edited, target: .tags))
    XCTAssertFalse(enrichmentNeedsConfirm(record: edited, target: .summary))
  }

  func testNoConfirm_forUneditedOrMissingRecord() {
    let clean = makeRecord(narrative: "Text.")
    XCTAssertFalse(enrichmentNeedsConfirm(record: clean, target: .summary))
    XCTAssertFalse(enrichmentNeedsConfirm(record: nil, target: .summary))
    XCTAssertFalse(enrichmentNeedsConfirm(record: nil, target: .tags))
  }
}

// MARK: - Dashboard pill predicate

final class TranscriptPillTests: XCTestCase {
  func testPillOnlyForTranscribedStatus() {
    XCTAssertTrue(showsTranscriptPill(recordStatus: "transcribed"))
    XCTAssertFalse(showsTranscriptPill(recordStatus: "completed"))
    XCTAssertFalse(showsTranscriptPill(recordStatus: nil))
  }
}

// MARK: - Enrichment-section stripping (display only)

final class EnrichmentStripTests: XCTestCase {
  func testStrip_removesSummaryAndTopics_keepsMetaAndTranscript() {
    let markdown = """
    # Title

    **Tags:** a, b

    ## Summary

    The narrative paragraph.

    ## Key Topics

    - one

    ## Full Transcript

    [0:01] **Speaker 1:** hi
    """

    let stripped = strippingEnrichmentSections(markdown)

    XCTAssertFalse(stripped.contains("## Summary"))
    XCTAssertFalse(stripped.contains("The narrative paragraph."))
    XCTAssertFalse(stripped.contains("## Key Topics"))
    XCTAssertFalse(stripped.contains("- one"))
    XCTAssertTrue(stripped.contains("## Full Transcript"))
    XCTAssertTrue(stripped.contains("**Tags:** a, b"))
  }

  func testStrip_noSummarySection_unchanged() {
    let markdown = "# Title\n\n## Full Transcript\n\nhello"
    XCTAssertEqual(strippingEnrichmentSections(markdown), markdown)
  }

  func testStrip_allFourSections_keepsRuleAndTranscript() {
    let markdown = """
    # Meeting Notes

    **Captured:** 2026-07-18

    ## Summary

    The narrative paragraph.

    ## Key Topics

    - Array-to-vector conversion — replacing pointer arithmetic
    - Job search

    ## Decisions Made

    - Ship variant B

    ## Action Items

    - [ ] File the PR

    ---

    ## Full Transcript

    [0:01] **Speaker 1:** hi
    """

    let stripped = strippingEnrichmentSections(markdown)

    XCTAssertTrue(stripped.contains("# Meeting Notes"))
    XCTAssertTrue(stripped.contains("**Captured:** 2026-07-18"))
    XCTAssertTrue(stripped.contains("---"))
    XCTAssertTrue(stripped.contains("## Full Transcript"))
    XCTAssertTrue(stripped.contains("[0:01] **Speaker 1:** hi"))
    XCTAssertFalse(stripped.contains("## Summary"))
    XCTAssertFalse(stripped.contains("## Key Topics"))
    XCTAssertFalse(stripped.contains("## Decisions Made"))
    XCTAssertFalse(stripped.contains("## Action Items"))
    XCTAssertFalse(stripped.contains("The narrative paragraph."))
    XCTAssertFalse(stripped.contains("Array-to-vector conversion"))
    XCTAssertFalse(stripped.contains("Job search"))
    XCTAssertFalse(stripped.contains("Ship variant B"))
    XCTAssertFalse(stripped.contains("File the PR"))
  }

  func testStrip_summaryOnly_removesJustNarrative() {
    let markdown = "# Title\n\n## Summary\n\nNarrative here.\n\n## Full Transcript\n\nhello"

    XCTAssertEqual(
      strippingEnrichmentSections(markdown),
      "# Title\n\n## Full Transcript\n\nhello"
    )
  }

  func testStrip_sectionsInDifferentOrder_allStripped() {
    let markdown = """
    # Title

    ## Action Items

    - [ ] File the PR

    ## Key Topics

    - Job search

    ## Summary

    The narrative paragraph.

    ## Decisions Made

    - Ship variant B

    ## Full Transcript

    hello
    """

    let stripped = strippingEnrichmentSections(markdown)

    XCTAssertFalse(stripped.contains("## Summary"))
    XCTAssertFalse(stripped.contains("## Key Topics"))
    XCTAssertFalse(stripped.contains("## Decisions Made"))
    XCTAssertFalse(stripped.contains("## Action Items"))
    XCTAssertFalse(stripped.contains("File the PR"))
    XCTAssertFalse(stripped.contains("Job search"))
    XCTAssertFalse(stripped.contains("The narrative paragraph."))
    XCTAssertFalse(stripped.contains("Ship variant B"))
    XCTAssertTrue(stripped.contains("# Title"))
    XCTAssertTrue(stripped.contains("## Full Transcript"))
    XCTAssertTrue(stripped.contains("hello"))
  }

  func testStrip_noEnrichmentSections_byteIdentical() {
    let markdown = "# Title\n\n## Notes\n\ntext\n\n---\n\n## Full Transcript\n\nhello"
    XCTAssertEqual(strippingEnrichmentSections(markdown), markdown)
  }
}

// MARK: - Topic chip parts (term + hover detail)

final class TopicChipPartsTests: XCTestCase {
  func testEmDashSeparator_splitsTermAndDetail() {
    let parts = topicChipParts("Array-to-vector conversion — replacing pointer arithmetic")
    XCTAssertEqual(parts.term, "Array-to-vector conversion")
    XCTAssertEqual(parts.detail, "replacing pointer arithmetic")
  }

  func testNoSeparator_detailIsNil() {
    let parts = topicChipParts("Job search")
    XCTAssertEqual(parts.term, "Job search")
    XCTAssertNil(parts.detail)
  }

  func testPlainHyphen_isNotASeparator() {
    let parts = topicChipParts("cost-benefit - tradeoffs")
    XCTAssertEqual(parts.term, "cost-benefit - tradeoffs")
    XCTAssertNil(parts.detail)
  }

  func testMultipleSeparators_splitsAtTheFirst() {
    let parts = topicChipParts("A — B — C")
    XCTAssertEqual(parts.term, "A")
    XCTAssertEqual(parts.detail, "B — C")
  }

  func testEmptyRemainderAfterSeparator_detailIsNil() {
    let parts = topicChipParts("Job search — ")
    XCTAssertEqual(parts.term, "Job search")
    XCTAssertNil(parts.detail)
  }
}

final class InlineMarkdownTests: XCTestCase {
  func testStrippingBold() {
    XCTAssertEqual(
      strippingInlineMarkdown("**Build a simple prototype first**"),
      "Build a simple prototype first"
    )
  }

  func testStrippingMixedInline() {
    XCTAssertEqual(
      strippingInlineMarkdown("Use *iterators* and `Vec<T>` — **not** raw pointers"),
      "Use iterators and Vec<T> — not raw pointers"
    )
  }

  func testPlainTextPassesThrough() {
    XCTAssertEqual(
      strippingInlineMarkdown("Email Michael about availability"),
      "Email Michael about availability"
    )
  }

  func testAttributedKeepsBoldRun() {
    let attributed = inlineMarkdownAttributed("**Lead** — rest")
    XCTAssertEqual(String(attributed.characters), "Lead — rest")
    let leadRun = attributed.runs.first
    XCTAssertNotNil(leadRun?.inlinePresentationIntent)
    XCTAssertTrue(
      leadRun?.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
    )
  }

  func testUnclosedMarkerFallsBackToRawText() {
    // Inline parser treats a dangling ** as literal; either way the text must
    // never be lost.
    XCTAssertTrue(
      strippingInlineMarkdown("**Unclosed lead — rest").contains("Unclosed lead")
    )
  }
}

// MARK: - Controller (process layer mocked)

@MainActor
final class EnrichmentControllerTests: XCTestCase {
  private func makeController(
    runner: EnrichmentProcessRunning,
    record: EnrichmentRecord? = makeRecord()
  ) -> EnrichmentController {
    let controller = EnrichmentController(
      runner: runner,
      summaryModelResolver: { "gpt-5-mini" }
    )
    controller.setRecord(record)
    return controller
  }

  func testGenerateSummary_spawnsSummarizeVerb_andUpdatesRecord() async throws {
    let runner = MockEnrichmentRunner()
    runner.result = .success(try recordJSON(status: "completed"))
    let controller = makeController(runner: runner)

    var updates: [(EnrichmentRecord, EnrichmentController.UpdateKind)] = []
    controller.onRecordUpdated = { updates.append(($0, $1)) }

    let task = controller.generateSummary()
    XCTAssertEqual(controller.activity, .summarizing)
    XCTAssertEqual(controller.generatingModelID, "gpt-5-mini")
    await task?.value

    XCTAssertEqual(runner.calls.count, 1)
    XCTAssertEqual(runner.calls[0].arguments, ["summarize", "rec-1"])
    XCTAssertNil(runner.calls[0].stdinJSON)
    XCTAssertEqual(controller.activity, .idle)
    XCTAssertEqual(controller.record?.status, "completed")
    XCTAssertEqual(updates.count, 1)
    XCTAssertEqual(updates[0].1, .generated)
  }

  func testGenerateSummary_force_appendsForceFlag() async throws {
    let runner = MockEnrichmentRunner()
    runner.result = .success(try recordJSON())
    let controller = makeController(runner: runner)

    await controller.generateSummary(force: true)?.value

    XCTAssertEqual(runner.calls[0].arguments, ["summarize", "rec-1", "--force"])
  }

  func testGenerateTags_spawnsTagVerb() async throws {
    let runner = MockEnrichmentRunner()
    runner.result = .success(try recordJSON(status: "transcribed", narrative: nil))
    let controller = makeController(runner: runner)

    let task = controller.generateTags()
    XCTAssertEqual(controller.activity, .tagging)
    await task?.value

    XCTAssertEqual(runner.calls[0].arguments, ["tag", "rec-1"])
    XCTAssertEqual(controller.activity, .idle)
  }

  func testCancelGeneration_killsRun_nothingApplied() async {
    let controller = makeController(runner: HangingEnrichmentRunner())
    let before = controller.record

    let task = controller.generateSummary()
    XCTAssertEqual(controller.activity, .summarizing)

    controller.cancelGeneration()
    XCTAssertEqual(controller.activity, .idle)
    await task?.value

    XCTAssertEqual(controller.record, before)
    XCTAssertNil(controller.errorMessage)
    XCTAssertEqual(controller.activity, .idle)
  }

  func testGenerateFailure_surfacesError_keepsRecord() async {
    let runner = MockEnrichmentRunner()
    runner.result = .failure(EnrichmentCLIError.cliFailed(2, stderr: "summary was edited; pass --force"))
    let controller = makeController(runner: runner)
    let before = controller.record

    await controller.generateSummary()?.value

    XCTAssertEqual(controller.errorMessage, "summary was edited; pass --force")
    XCTAssertEqual(controller.record, before)
    XCTAssertEqual(controller.activity, .idle)
  }

  func testGenerate_undecodableStdout_surfacesError() async {
    let runner = MockEnrichmentRunner()
    runner.result = .success(Data("oops".utf8))
    let controller = makeController(runner: runner)

    await controller.generateSummary()?.value

    XCTAssertNotNil(controller.errorMessage)
    XCTAssertEqual(controller.record?.status, "transcribed")
  }

  func testSaveSummaryEdit_sendsApplyEnrichmentPayload() async throws {
    let runner = MockEnrichmentRunner()
    runner.result = .success(try recordJSON(summaryEdited: true))
    let controller = makeController(
      runner: runner,
      record: makeRecord(status: "completed", narrative: "Old text.")
    )

    var kinds: [EnrichmentController.UpdateKind] = []
    controller.onRecordUpdated = { kinds.append($1) }

    await controller.saveSummaryEdit("  New text.  ")?.value

    XCTAssertEqual(runner.calls.count, 1)
    XCTAssertEqual(runner.calls[0].arguments, ["history", "apply-enrichment", "rec-1", "--json"])
    let payload = try XCTUnwrap(runner.calls[0].stdinJSON)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    XCTAssertEqual(json["summary"] as? String, "New text.")
    XCTAssertEqual(json["summaryEdited"] as? Bool, true)
    XCTAssertNil(json["tags"])
    XCTAssertNil(json["tagsEdited"])
    XCTAssertEqual(kinds, [.edited])
    XCTAssertEqual(controller.record?.isSummaryEdited, true)
  }

  func testSaveSummaryEdit_emptyText_neverWrites() {
    let runner = MockEnrichmentRunner()
    let controller = makeController(
      runner: runner,
      record: makeRecord(status: "completed", narrative: "Old text.")
    )

    XCTAssertNil(controller.saveSummaryEdit("   \n  "))
    XCTAssertTrue(runner.calls.isEmpty)
  }

  func testAddTag_appendsNormalized_marksTagsEdited() async throws {
    let runner = MockEnrichmentRunner()
    runner.result = .success(try recordJSON(tags: ["planning", "roadmap"], tagsEdited: true))
    let controller = makeController(runner: runner, record: makeRecord(tags: ["planning"]))

    await controller.addTag("  Roadmap ")?.value

    let payload = try XCTUnwrap(runner.calls[0].stdinJSON)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    XCTAssertEqual(json["tags"] as? [String], ["planning", "roadmap"])
    XCTAssertEqual(json["tagsEdited"] as? Bool, true)
    XCTAssertNil(json["summary"])
  }

  func testAddTag_duplicateIsIgnored() {
    let runner = MockEnrichmentRunner()
    let controller = makeController(runner: runner, record: makeRecord(tags: ["planning"]))

    XCTAssertNil(controller.addTag("PLANNING"))
    XCTAssertTrue(runner.calls.isEmpty)
  }

  func testRemoveTag_filtersTag_marksTagsEdited() async throws {
    let runner = MockEnrichmentRunner()
    runner.result = .success(try recordJSON(tags: ["roadmap"], tagsEdited: true))
    let controller = makeController(runner: runner, record: makeRecord(tags: ["planning", "roadmap"]))

    await controller.removeTag("planning")?.value

    let payload = try XCTUnwrap(runner.calls[0].stdinJSON)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    XCTAssertEqual(json["tags"] as? [String], ["roadmap"])
    XCTAssertEqual(json["tagsEdited"] as? Bool, true)
  }

  func testRemoveTag_unknownTag_noCall() {
    let runner = MockEnrichmentRunner()
    let controller = makeController(runner: runner, record: makeRecord(tags: ["planning"]))

    XCTAssertNil(controller.removeTag("missing"))
    XCTAssertTrue(runner.calls.isEmpty)
  }

  func testSetRecord_clearsErrorAndCancelsGeneration() {
    let controller = makeController(runner: HangingEnrichmentRunner())
    controller.generateSummary()
    XCTAssertEqual(controller.activity, .summarizing)

    controller.setRecord(makeRecord(id: "rec-2"))

    XCTAssertEqual(controller.activity, .idle)
    XCTAssertEqual(controller.record?.id, "rec-2")
  }
}

// MARK: - Speaker suggestion decode (decision 4)

final class SpeakerSuggestionDecodeTests: XCTestCase {
  func testDecode_pendingSuggestionCarriesFullShape() throws {
    let data = try recordJSON(
      suggestions: [suggestionJSON(score: 0.623)],
      summaryOutdated: true
    )
    let record = try EnrichmentRecord.decode(data)

    XCTAssertEqual(record.pendingSuggestions.count, 1)
    let suggestion = try XCTUnwrap(record.pendingSuggestions.first)
    XCTAssertEqual(suggestion.label, "Speaker 2")
    XCTAssertEqual(suggestion.suggestedName, "Kenny Kim")
    XCTAssertEqual(suggestion.score, 0.623, accuracy: 0.0001)
    XCTAssertEqual(suggestion.voiceprintId, "20260717-004104Z")
    XCTAssertEqual(suggestion.state, "pending")
    XCTAssertTrue(suggestion.isPending)
    XCTAssertNil(suggestion.decidedAt)
    XCTAssertEqual(suggestion.scoreText, "0.62")
    XCTAssertTrue(record.isSummaryOutdated)
  }

  func testDecode_decidedSuggestionIsNotPending() throws {
    let data = try recordJSON(
      suggestions: [
        suggestionJSON(state: "accepted", decidedAt: "2026-07-18T10:00:00.000Z"),
        suggestionJSON(label: "Speaker 3", state: "dismissed", decidedAt: "2026-07-18T10:00:00.000Z"),
      ]
    )
    let record = try EnrichmentRecord.decode(data)

    XCTAssertTrue(record.pendingSuggestions.isEmpty)
    XCTAssertEqual(record.suggestions?.count, 2)
  }

  func testDecode_unknownSuggestionStateDegradesToNotPending() throws {
    let data = try recordJSON(suggestions: [suggestionJSON(state: "maybe")])
    let record = try EnrichmentRecord.decode(data)

    XCTAssertTrue(record.pendingSuggestions.isEmpty)
  }

  func testDecode_legacyRecordWithoutSuggestionFieldsLoadsExactlyAsBefore() throws {
    let data = try recordJSON()
    let record = try EnrichmentRecord.decode(data)

    XCTAssertNil(record.suggestions)
    XCTAssertNil(record.summaryOutdated)
    XCTAssertTrue(record.pendingSuggestions.isEmpty)
    XCTAssertFalse(record.isSummaryOutdated)
    XCTAssertEqual(record.id, "rec-1")
    XCTAssertEqual(record.summary?.narrative, "A generated narrative.")
  }

  func testDecode_partialSuggestionEntryIsTolerated() throws {
    // A suggestion missing its id/state must not fail the whole record decode
    // — it degrades to not-pending and is dropped by the chip map.
    let data = try recordJSON(
      suggestions: [["label": "Speaker 2", "suggestedName": "Kenny Kim", "score": 0.5]]
    )
    let record = try EnrichmentRecord.decode(data)

    XCTAssertEqual(record.suggestions?.count, 1)
    XCTAssertTrue(record.pendingSuggestions.isEmpty)
  }

  func testRegeneratedSummaryClearsOutdatedFlag() throws {
    // The CLI writes summaryOutdated: false when it sets a fresh summary
    // (src/pipeline/history.ts) — decode must surface the cleared flag.
    let data = try recordJSON(summaryOutdated: false)
    let record = try EnrichmentRecord.decode(data)

    XCTAssertFalse(record.isSummaryOutdated)
  }
}

// MARK: - Pending-suggestion map (chip threading)

final class PendingSuggestionMapTests: XCTestCase {
  func testMap_keepsOnlyPendingEntries_ByLabel() {
    let pending = SpeakerSuggestion(
      label: "Speaker 2", suggestedName: "Kenny Kim", score: 0.62,
      voiceprintId: "a", state: "pending", decidedAt: nil
    )
    let accepted = SpeakerSuggestion(
      label: "Speaker 1", suggestedName: "Alice", score: 0.8,
      voiceprintId: "b", state: "accepted", decidedAt: "2026-07-18T10:00:00.000Z"
    )

    let map = pendingSuggestionMap([pending, accepted])

    XCTAssertEqual(map.count, 1)
    XCTAssertEqual(map["Speaker 2"], pending)
    XCTAssertNil(map["Speaker 1"])
  }

  func testMap_lastPendingWinsPerLabel() {
    let first = SpeakerSuggestion(
      label: "Speaker 2", suggestedName: "Kenny Kim", score: 0.62,
      voiceprintId: "a", state: "pending", decidedAt: nil
    )
    let second = SpeakerSuggestion(
      label: "Speaker 2", suggestedName: "Kenny Kim", score: 0.71,
      voiceprintId: "b", state: "pending", decidedAt: nil
    )

    let map = pendingSuggestionMap([first, second])

    XCTAssertEqual(map["Speaker 2"], second)
  }

  func testMap_emptyInput() {
    XCTAssertTrue(pendingSuggestionMap([]).isEmpty)
  }
}

// MARK: - Regenerate-summary affordance (decision 5)

final class SummaryOutdatedDismissTests: XCTestCase {
  @MainActor
  func testDismissSummaryOutdated_writesFalseThroughApplyEnrichment() async throws {
    let runner = MockEnrichmentRunner()
    runner.result = .success(try recordJSON())
    let controller = EnrichmentController(
      runner: runner,
      summaryModelResolver: { "gpt-5-mini" }
    )
    // Any installed record works — dismissal only writes the flag.
    controller.setRecord(makeRecord(status: "completed", narrative: "Old text."))

    var kinds: [EnrichmentController.UpdateKind] = []
    controller.onRecordUpdated = { kinds.append($1) }

    await controller.dismissSummaryOutdated()?.value

    XCTAssertEqual(runner.calls.count, 1)
    XCTAssertEqual(runner.calls[0].arguments, ["history", "apply-enrichment", "rec-1", "--json"])
    let payload = try XCTUnwrap(runner.calls[0].stdinJSON)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
    XCTAssertEqual(json["summaryOutdated"] as? Bool, false)
    // Dismissal touches nothing else.
    XCTAssertNil(json["summary"])
    XCTAssertNil(json["summaryEdited"])
    XCTAssertNil(json["tags"])
    XCTAssertNil(json["tagsEdited"])
    XCTAssertEqual(kinds, [.edited])
  }
}

// MARK: - Voiceprint low-agreement flag (decision 6)

final class VoiceprintLowAgreementTests: XCTestCase {
  private func decodeStore(_ json: [String: Any]) throws -> SpeakerStore {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(SpeakerStore.self, from: data)
  }

  func testDecode_v4VoiceprintWithLowAgreementFlag() throws {
    let store = try decodeStore([
      "version": 4,
      "speakers": [
        "Kenny Kim": [
          "voiceprints": [[
            "id": "20260717-004104Z",
            "embedding": [0.1, 0.2],
            "enrolledAt": "2026-07-17T00:41:04.000Z",
            "source": "hist-1",
            "lowAgreement": true,
          ]],
        ],
      ],
    ])

    let voiceprint = try XCTUnwrap(store.speakers["Kenny Kim"]?.voiceprints.first)
    XCTAssertEqual(voiceprint.lowAgreement, true)
  }

  func testDecode_absentFlagReadsNil() throws {
    let store = try decodeStore([
      "version": 4,
      "speakers": [
        "Kenny Kim": [
          "voiceprints": [[
            "id": "20260717-004104Z",
            "embedding": [0.1, 0.2],
            "enrolledAt": "2026-07-17T00:41:04.000Z",
            "source": "hist-1",
          ]],
        ],
      ],
    ])

    let voiceprint = try XCTUnwrap(store.speakers["Kenny Kim"]?.voiceprints.first)
    XCTAssertNil(voiceprint.lowAgreement)
  }

  func testDecode_v1LegacyProfileStillMigrates() throws {
    // Legacy flat profile shape (embedding/enrolledAt/source at the top):
    // the migration decoder must keep working with the new field added.
    let store = try decodeStore([
      "version": 2,
      "speakers": [
        "Kenny Kim": [
          "embedding": [0.1, 0.2],
          "enrolledAt": "2026-07-17T00:41:04.000Z",
          "source": "hist-1",
        ],
      ],
    ])

    let profile = try XCTUnwrap(store.speakers["Kenny Kim"])
    XCTAssertEqual(profile.voiceprints.count, 1)
    XCTAssertEqual(profile.voiceprints.first?.id, "2026-07-17T00:41:04.000Z")
    XCTAssertNil(profile.voiceprints.first?.lowAgreement)
  }

  func testEncode_omitsAbsentLowAgreement() throws {
    let voiceprint = Voiceprint(
      id: "a", embedding: [0.1], enrolledAt: "2026-07-17T00:41:04.000Z",
      source: "hist-1", lowAgreement: nil
    )
    let data = try JSONEncoder().encode(voiceprint)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertNil(json["lowAgreement"], "absent flag must not be written as null")
  }
}

// MARK: - Generic-label predicate

/// A chip whose label is already a person's name (auto-identified at run
/// time) is named, whatever the sidecar says — only diarizer placeholders
/// ("Speaker 3") may render the dashed unnamed state.
final class SpeakerChipGenericLabelTests: XCTestCase {
  func testDiarizerPlaceholdersAreGeneric() {
    XCTAssertTrue(SpeakerChip.isGenericLabel("Speaker 1"))
    XCTAssertTrue(SpeakerChip.isGenericLabel("Speaker 12"))
  }

  func testPersonNamesAndOddLabelsAreNot() {
    XCTAssertFalse(SpeakerChip.isGenericLabel("Freya Wu"))
    XCTAssertFalse(SpeakerChip.isGenericLabel("Meghan Casey"))
    // Not the diarizer's shape: prefixes and suffixes don't count.
    XCTAssertFalse(SpeakerChip.isGenericLabel("Speaker 1 (guest)"))
    XCTAssertFalse(SpeakerChip.isGenericLabel("Guest Speaker 1"))
    XCTAssertFalse(SpeakerChip.isGenericLabel("Speaker"))
  }

  func testChipExposesThePredicate() {
    XCTAssertFalse(SpeakerChip(label: "Freya Wu", name: "", indicator: .none).hasGenericLabel)
    XCTAssertTrue(SpeakerChip(label: "Speaker 2", name: "", indicator: .none).hasGenericLabel)
  }
}
