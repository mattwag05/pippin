import ArgumentParser
@testable import PippinLib
import XCTest

final class ActionsCommandTests: XCTestCase {
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
}
