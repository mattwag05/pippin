import ArgumentParser
@testable import PippinLib
import XCTest

final class ActionsCommandTests: XCTestCase {
    /// Unlimited-budget shorthand for the budget-aware extract: fail-fast,
    /// actions only (the shape the CLI convenience overload used to provide).
    private func extractUnbounded(
        items: [ActionExtractor.Item],
        provider: any AIProvider,
        minConfidence: Float = 0.5
    ) throws -> [ExtractedAction] {
        try ActionExtractor.extract(items: items, provider: provider, minConfidence: minConfidence, budget: BatchBudget(softTimeoutMs: 0)).actions
    }

    // MARK: - Configuration

    func testActionsCommandName() {
        XCTAssertEqual(ActionsCommand.configuration.commandName, "actions")
    }

    func testActionsCommandHasExtractSubcommand() {
        let names = ActionsCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("extract"), "Expected 'extract' subcommand, got: \(names)")
    }

    func testExtractCommandName() {
        XCTAssertEqual(ActionsCommand.Extract.configuration.commandName, "extract")
    }

    // MARK: - Extract flag parsing

    func testExtractDefaultsParse() throws {
        let cmd = try ActionsCommand.Extract.parse([])
        XCTAssertEqual(cmd.days, 7)
        XCTAssertTrue(cmd.mail)
        XCTAssertTrue(cmd.notes)
        XCTAssertEqual(cmd.limit, 50)
        XCTAssertEqual(cmd.minConfidence, 0.5, accuracy: 0.0001)
        XCTAssertFalse(cmd.create)
    }

    func testExtractDaysFlagParses() throws {
        let cmd = try ActionsCommand.Extract.parse(["--days", "14"])
        XCTAssertEqual(cmd.days, 14)
    }

    func testExtractNoMailInversion() throws {
        let cmd = try ActionsCommand.Extract.parse(["--no-mail"])
        XCTAssertFalse(cmd.mail)
        XCTAssertTrue(cmd.notes)
    }

    func testExtractNoNotesInversion() throws {
        let cmd = try ActionsCommand.Extract.parse(["--no-notes"])
        XCTAssertTrue(cmd.mail)
        XCTAssertFalse(cmd.notes)
    }

    func testExtractCreateFlag() throws {
        let cmd = try ActionsCommand.Extract.parse(["--create"])
        XCTAssertTrue(cmd.create)
    }

    func testExtractListOption() throws {
        let cmd = try ActionsCommand.Extract.parse(["--list", "Work"])
        XCTAssertEqual(cmd.list, "Work")
    }

    func testExtractProviderOption() throws {
        let cmd = try ActionsCommand.Extract.parse(["--provider", "claude", "--model", "claude-sonnet-4-6"])
        XCTAssertEqual(cmd.provider, "claude")
        XCTAssertEqual(cmd.model, "claude-sonnet-4-6")
    }

    func testExtractAgentFormatPasses() {
        XCTAssertNoThrow(try ActionsCommand.Extract.parse(["--format", "agent"]))
    }

    func testExtractAllOptionsParse() throws {
        let cmd = try ActionsCommand.Extract.parse([
            "--days", "3",
            "--no-notes",
            "--account", "Work",
            "--limit", "20",
            "--min-confidence", "0.7",
            "--provider", "ollama",
            "--create",
            "--list", "Follow-ups",
            "--format", "json",
        ])
        XCTAssertEqual(cmd.days, 3)
        XCTAssertTrue(cmd.mail)
        XCTAssertFalse(cmd.notes)
        XCTAssertEqual(cmd.account, "Work")
        XCTAssertEqual(cmd.limit, 20)
        XCTAssertEqual(cmd.minConfidence, 0.7, accuracy: 0.0001)
        XCTAssertTrue(cmd.create)
        XCTAssertEqual(cmd.list, "Follow-ups")
    }

    // MARK: - Validation

    func testExtractRejectsZeroDays() {
        XCTAssertThrowsError(try ActionsCommand.Extract.parseAsRoot(["--days", "0"]))
    }

    func testExtractRejectsTooManyDays() {
        XCTAssertThrowsError(try ActionsCommand.Extract.parseAsRoot(["--days", "91"]))
    }

    func testExtractRejectsZeroLimit() {
        XCTAssertThrowsError(try ActionsCommand.Extract.parseAsRoot(["--limit", "0"]))
    }

    func testExtractRejectsConfidenceOutOfRange() {
        XCTAssertThrowsError(try ActionsCommand.Extract.parseAsRoot(["--min-confidence", "1.5"]))
        XCTAssertThrowsError(try ActionsCommand.Extract.parseAsRoot(["--min-confidence", "-0.1"]))
    }

    func testExtractRejectsNoSources() {
        XCTAssertThrowsError(try ActionsCommand.Extract.parseAsRoot(["--no-mail", "--no-notes"]))
    }

    // MARK: - Template

    func testExtractActionsTemplateExists() {
        let names = BuiltInTemplates.all.map { $0.name }
        XCTAssertTrue(names.contains("extract-actions"))
    }

    func testExtractActionsTemplateHasCurrentDatePlaceholder() {
        XCTAssertTrue(BuiltInTemplates.extractActions.content.contains("{{CURRENT_DATE}}"))
    }

    func testExtractActionsTemplateHasCurrentTimePlaceholder() {
        XCTAssertTrue(BuiltInTemplates.extractActions.content.contains("{{CURRENT_TIME}}"))
    }

    func testExtractActionsTemplateRequiresRawJSONOutput() {
        XCTAssertTrue(BuiltInTemplates.extractActions.content.contains("ONLY a raw JSON"))
    }

    func testExtractActionsTemplateDocumentsActionsKey() {
        XCTAssertTrue(BuiltInTemplates.extractActions.content.contains("\"actions\""))
    }

    // MARK: - Model round-trip

    func testExtractedActionRoundTripsThroughJSON() throws {
        let original = ExtractedAction(
            source: .mail,
            sourceId: "acct||Sent||ABC123",
            sourceTitle: "Re: Q3 report",
            snippet: "I'll send the updated numbers by Friday.",
            proposedTitle: "Send Q3 numbers to Alex",
            proposedDueDate: "2026-04-24T17:00:00",
            proposedPriority: 5,
            confidence: 0.87
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ExtractedAction.self, from: encoded)
        XCTAssertEqual(decoded.source, .mail)
        XCTAssertEqual(decoded.sourceId, original.sourceId)
        XCTAssertEqual(decoded.sourceTitle, "Re: Q3 report")
        XCTAssertEqual(decoded.snippet, original.snippet)
        XCTAssertEqual(decoded.proposedTitle, original.proposedTitle)
        XCTAssertEqual(decoded.proposedDueDate, "2026-04-24T17:00:00")
        XCTAssertEqual(decoded.proposedPriority, 5)
        XCTAssertEqual(decoded.confidence, 0.87, accuracy: 0.0001)
    }

    func testActionSourceRawValues() {
        XCTAssertEqual(ActionSource.mail.rawValue, "mail")
        XCTAssertEqual(ActionSource.note.rawValue, "note")
    }

    // MARK: - ActionExtractor engine

    func testExtractReturnsActionsAboveMinConfidence() throws {
        let json = """
        {"actions":[
          {"sourceIndex":0,"snippet":"I'll send you Q3.","proposedTitle":"Send Q3","proposedDueDate":null,"proposedPriority":0,"confidence":0.9},
          {"sourceIndex":1,"snippet":"Maybe later.","proposedTitle":"Follow up","proposedDueDate":null,"proposedPriority":0,"confidence":0.2}
        ]}
        """
        let provider = FakeActionProvider(response: json)
        let items = [
            ActionExtractor.Item(source: .mail, sourceId: "1", sourceTitle: "Email", text: "I'll send you Q3."),
            ActionExtractor.Item(source: .note, sourceId: "2", sourceTitle: "Note", text: "Maybe later."),
        ]
        let results = try extractUnbounded(items: items, provider: provider)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].proposedTitle, "Send Q3")
        XCTAssertEqual(results[0].source, .mail)
    }

    func testExtractMapsSourceIndexToCorrectItem() throws {
        let json = """
        {"actions":[
          {"sourceIndex":1,"snippet":"I'll draft the report.","proposedTitle":"Draft report","proposedDueDate":null,"proposedPriority":0,"confidence":0.85}
        ]}
        """
        let provider = FakeActionProvider(response: json)
        let items = [
            ActionExtractor.Item(source: .mail, sourceId: "a", sourceTitle: "Mail", text: "Nothing here."),
            ActionExtractor.Item(source: .note, sourceId: "b", sourceTitle: "Note", text: "I'll draft the report."),
        ]
        let results = try extractUnbounded(items: items, provider: provider)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].source, .note)
        XCTAssertEqual(results[0].sourceId, "b")
    }

    func testExtractHandlesMarkdownFencedJSON() throws {
        let json = """
        ```json
        {"actions":[
          {"sourceIndex":0,"snippet":"I'll follow up.","proposedTitle":"Follow up","proposedDueDate":null,"proposedPriority":0,"confidence":0.75}
        ]}
        ```
        """
        let provider = FakeActionProvider(response: json)
        let items = [ActionExtractor.Item(source: .mail, sourceId: "1", sourceTitle: nil, text: "I'll follow up.")]
        let results = try extractUnbounded(items: items, provider: provider)
        XCTAssertEqual(results.count, 1)
    }

    func testExtractThrowsOnMalformedResponse() throws {
        let provider = FakeActionProvider(response: "not json at all")
        let items = [ActionExtractor.Item(source: .mail, sourceId: "1", sourceTitle: nil, text: "body")]
        XCTAssertThrowsError(try extractUnbounded(items: items, provider: provider)) { error in
            XCTAssertTrue(error is ActionExtractorError)
        }
    }

    func testExtractReturnsEmptyForEmptyItems() throws {
        let provider = FakeActionProvider(response: "{\"actions\":[]}")
        let results = try extractUnbounded(items: [], provider: provider)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Budget-aware extraction (pippin-hzg)

    func testExtractBudgetTimeoutReturnsPartialWithoutWaiting() throws {
        // 30 items / batchSize 10 = 3 batches, each sleeping 2s. A 150ms budget
        // fires first → the call returns at the deadline (not after 2s), flags
        // timedOut, and does NOT throw — the no-SIGKILL/partial contract.
        let provider = SlowActionProvider(response: "{\"actions\":[]}", delay: 2.0)
        let items = (0 ..< 30).map {
            ActionExtractor.Item(source: .mail, sourceId: "\($0)", sourceTitle: nil, text: "x")
        }
        let start = Date()
        let (actions, timedOut) = try ActionExtractor.extract(
            items: items, provider: provider, minConfidence: 0.5, budget: BatchBudget(softTimeoutMs: 150)
        )
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(timedOut, "budget should fire before the 2s batches finish")
        XCTAssertLessThan(elapsed, 1.5, "should return at the budget, not wait for slow batches (saw \(elapsed)s)")
        XCTAssertTrue(actions.isEmpty, "all batches were still running at the deadline")
    }

    func testExtractUnlimitedBudgetCompletesWithoutTimedOut() throws {
        let json = """
        {"actions":[
          {"sourceIndex":0,"snippet":"I'll send Q3.","proposedTitle":"Send Q3","proposedDueDate":null,"proposedPriority":0,"confidence":0.9}
        ]}
        """
        let provider = FakeActionProvider(response: json)
        let items = [ActionExtractor.Item(source: .mail, sourceId: "1", sourceTitle: nil, text: "I'll send Q3.")]
        let (actions, timedOut) = try ActionExtractor.extract(
            items: items, provider: provider, minConfidence: 0.5, budget: BatchBudget(softTimeoutMs: 0)
        )
        XCTAssertFalse(timedOut)
        XCTAssertEqual(actions.count, 1)
    }
}

private struct SlowActionProvider: AIProvider {
    let response: String
    let delay: TimeInterval
    func complete(prompt _: String, system _: String) throws -> String {
        Thread.sleep(forTimeInterval: delay)
        return response
    }
}

private struct FakeActionProvider: AIProvider {
    let response: String
    func complete(prompt _: String, system _: String) throws -> String {
        response
    }
}
