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
  tagsEdited: Bool? = nil
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
  return try JSONSerialization.data(withJSONObject: record)
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
