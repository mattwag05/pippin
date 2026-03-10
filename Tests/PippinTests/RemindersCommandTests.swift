@testable import PippinLib
import XCTest

/// Tests for ArgumentParser `validate()` logic in RemindersCommand subcommands.
final class RemindersCommandTests: XCTestCase {
    // MARK: - Configuration

    func testRemindersCommandHasExpectedSubcommands() {
        let subcommandNames = RemindersCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommandNames.contains("lists"), "Expected 'lists' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("list"), "Expected 'list' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("show"), "Expected 'show' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("create"), "Expected 'create' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("edit"), "Expected 'edit' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("complete"), "Expected 'complete' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("delete"), "Expected 'delete' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("search"), "Expected 'search' subcommand, got: \(subcommandNames)")
    }

    func testRemindersCommandName() {
        XCTAssertEqual(RemindersCommand.configuration.commandName, "reminders")
    }

    func testListsCommandName() {
        XCTAssertEqual(RemindersCommand.Lists.configuration.commandName, "lists")
    }

    func testListCommandName() {
        XCTAssertEqual(RemindersCommand.List.configuration.commandName, "list")
    }

    func testShowCommandName() {
        XCTAssertEqual(RemindersCommand.Show.configuration.commandName, "show")
    }

    func testCreateCommandName() {
        XCTAssertEqual(RemindersCommand.Create.configuration.commandName, "create")
    }

    func testEditCommandName() {
        XCTAssertEqual(RemindersCommand.Edit.configuration.commandName, "edit")
    }

    func testCompleteCommandName() {
        XCTAssertEqual(RemindersCommand.Complete.configuration.commandName, "complete")
    }

    func testDeleteCommandName() {
        XCTAssertEqual(RemindersCommand.Delete.configuration.commandName, "delete")
    }

    func testSearchCommandName() {
        XCTAssertEqual(RemindersCommand.Search.configuration.commandName, "search")
    }

    // MARK: - Lists subcommand

    func testListsNoArgsPasses() {
        XCTAssertNoThrow(try RemindersCommand.Lists.parse([]))
    }

    func testListsJsonFormatPasses() {
        XCTAssertNoThrow(try RemindersCommand.Lists.parse(["--format", "json"]))
    }

    // MARK: - List subcommand

    func testListNoArgsPasses() {
        XCTAssertNoThrow(try RemindersCommand.List.parse([]))
    }

    func testListCompletedFlagPasses() {
        XCTAssertNoThrow(try RemindersCommand.List.parse(["--completed"]))
    }

    func testListDefaultLimitIs50() throws {
        let cmd = try RemindersCommand.List.parse([])
        XCTAssertEqual(cmd.limit, 50)
    }

    func testListCustomLimit() throws {
        let cmd = try RemindersCommand.List.parse(["--limit", "10"])
        XCTAssertEqual(cmd.limit, 10)
    }

    func testListZeroLimitFails() {
        XCTAssertThrowsError(try RemindersCommand.List.parse(["--limit", "0"]))
    }

    func testListValidDueBeforePasses() {
        XCTAssertNoThrow(try RemindersCommand.List.parse(["--due-before", "2026-03-15"]))
    }

    func testListInvalidDueBeforeFails() {
        XCTAssertThrowsError(try RemindersCommand.List.parse(["--due-before", "not-a-date"]))
    }

    func testListValidDueAfterPasses() {
        XCTAssertNoThrow(try RemindersCommand.List.parse(["--due-after", "2026-03-01"]))
    }

    func testListInvalidDueAfterFails() {
        XCTAssertThrowsError(try RemindersCommand.List.parse(["--due-after", "bad"]))
    }

    func testListValidPriorityHighPasses() {
        XCTAssertNoThrow(try RemindersCommand.List.parse(["--priority", "high"]))
    }

    func testListValidPriorityMediumPasses() {
        XCTAssertNoThrow(try RemindersCommand.List.parse(["--priority", "medium"]))
    }

    func testListValidPriorityLowPasses() {
        XCTAssertNoThrow(try RemindersCommand.List.parse(["--priority", "low"]))
    }

    func testListValidPriorityNonePasses() {
        XCTAssertNoThrow(try RemindersCommand.List.parse(["--priority", "none"]))
    }

    func testListInvalidPriorityFails() {
        XCTAssertThrowsError(try RemindersCommand.List.parse(["--priority", "urgent"]))
    }

    func testListJsonFormatPasses() {
        XCTAssertNoThrow(try RemindersCommand.List.parse(["--format", "json"]))
    }

    // MARK: - Show subcommand

    func testShowRequiresId() {
        XCTAssertThrowsError(try RemindersCommand.Show.parse([]))
    }

    func testShowWithIdPasses() {
        XCTAssertNoThrow(try RemindersCommand.Show.parse(["reminder-id"]))
    }

    func testShowJsonFormatPasses() {
        XCTAssertNoThrow(try RemindersCommand.Show.parse(["reminder-id", "--format", "json"]))
    }

    // MARK: - Create subcommand

    func testCreateRequiresTitle() {
        XCTAssertThrowsError(try RemindersCommand.Create.parse([]))
    }

    func testCreateWithTitlePasses() {
        XCTAssertNoThrow(try RemindersCommand.Create.parse(["Buy milk"]))
    }

    func testCreateValidDuePasses() {
        XCTAssertNoThrow(try RemindersCommand.Create.parse(["Task", "--due", "2026-03-15"]))
    }

    func testCreateInvalidDueFails() {
        XCTAssertThrowsError(try RemindersCommand.Create.parse(["Task", "--due", "tomorrow"]))
    }

    func testCreateValidPriorityPasses() {
        XCTAssertNoThrow(try RemindersCommand.Create.parse(["Task", "--priority", "high"]))
    }

    func testCreateInvalidPriorityFails() {
        XCTAssertThrowsError(try RemindersCommand.Create.parse(["Task", "--priority", "critical"]))
    }

    func testCreateWithAllOptionsPasses() {
        XCTAssertNoThrow(try RemindersCommand.Create.parse([
            "Buy groceries",
            "--due", "2026-03-15T10:00:00",
            "--priority", "medium",
            "--notes", "Milk and eggs",
            "--url", "https://example.com",
            "--format", "json",
        ]))
    }

    // MARK: - Edit subcommand

    func testEditRequiresId() {
        XCTAssertThrowsError(try RemindersCommand.Edit.parse([]))
    }

    func testEditIdOnlyPasses() {
        XCTAssertNoThrow(try RemindersCommand.Edit.parse(["reminder-id"]))
    }

    func testEditInvalidDueFails() {
        XCTAssertThrowsError(try RemindersCommand.Edit.parse(["reminder-id", "--due", "not-a-date"]))
    }

    func testEditInvalidPriorityFails() {
        XCTAssertThrowsError(try RemindersCommand.Edit.parse(["reminder-id", "--priority", "very-high"]))
    }

    func testEditValidFieldsPasses() {
        XCTAssertNoThrow(try RemindersCommand.Edit.parse([
            "reminder-id",
            "--title", "Updated title",
            "--due", "2026-03-20",
            "--priority", "low",
        ]))
    }

    // MARK: - Complete subcommand

    func testCompleteRequiresId() {
        XCTAssertThrowsError(try RemindersCommand.Complete.parse([]))
    }

    func testCompleteWithIdPasses() {
        XCTAssertNoThrow(try RemindersCommand.Complete.parse(["reminder-id"]))
    }

    func testCompleteJsonFormatPasses() {
        XCTAssertNoThrow(try RemindersCommand.Complete.parse(["reminder-id", "--format", "json"]))
    }

    // MARK: - Delete subcommand

    func testDeleteRequiresId() {
        XCTAssertThrowsError(try RemindersCommand.Delete.parse([]))
    }

    func testDeleteWithoutForceFails() {
        XCTAssertThrowsError(try RemindersCommand.Delete.parse(["reminder-id"]))
    }

    func testDeleteWithForcePasses() {
        XCTAssertNoThrow(try RemindersCommand.Delete.parse(["reminder-id", "--force"]))
    }

    func testDeleteWithForceAndJsonFormatPasses() {
        XCTAssertNoThrow(try RemindersCommand.Delete.parse(["reminder-id", "--force", "--format", "json"]))
    }

    // MARK: - Search subcommand

    func testSearchRequiresQuery() {
        XCTAssertThrowsError(try RemindersCommand.Search.parse([]))
    }

    func testSearchWithQueryPasses() {
        XCTAssertNoThrow(try RemindersCommand.Search.parse(["groceries"]))
    }

    func testSearchDefaultLimit() throws {
        let cmd = try RemindersCommand.Search.parse(["query"])
        XCTAssertEqual(cmd.limit, 50)
    }

    func testSearchCustomLimit() throws {
        let cmd = try RemindersCommand.Search.parse(["query", "--limit", "20"])
        XCTAssertEqual(cmd.limit, 20)
    }

    func testSearchZeroLimitFails() {
        XCTAssertThrowsError(try RemindersCommand.Search.parse(["query", "--limit", "0"]))
    }

    func testSearchCompletedFlagPasses() {
        XCTAssertNoThrow(try RemindersCommand.Search.parse(["query", "--completed"]))
    }

    func testSearchCompletedDefaultFalse() throws {
        let cmd = try RemindersCommand.Search.parse(["query"])
        XCTAssertFalse(cmd.completed)
    }

    func testSearchJsonFormatPasses() {
        XCTAssertNoThrow(try RemindersCommand.Search.parse(["query", "--format", "json"]))
    }

    func testSearchWithListPasses() {
        XCTAssertNoThrow(try RemindersCommand.Search.parse(["query", "--list", "list-id"]))
    }
}
