@testable import PippinLib
import XCTest

/// Tests for ArgumentParser `validate()` logic in NotesCommand subcommands.
final class NotesCommandTests: XCTestCase {
    // MARK: - Configuration

    func testNotesCommandHasExpectedSubcommands() {
        let subcommandNames = NotesCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(subcommandNames.contains("list"), "Expected 'list' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("show"), "Expected 'show' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("search"), "Expected 'search' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("folders"), "Expected 'folders' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("create"), "Expected 'create' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("edit"), "Expected 'edit' subcommand, got: \(subcommandNames)")
        XCTAssertTrue(subcommandNames.contains("delete"), "Expected 'delete' subcommand, got: \(subcommandNames)")
    }

    func testNotesCommandName() {
        XCTAssertEqual(NotesCommand.configuration.commandName, "notes")
    }

    func testListCommandName() {
        XCTAssertEqual(NotesCommand.List.configuration.commandName, "list")
    }

    func testShowCommandName() {
        XCTAssertEqual(NotesCommand.Show.configuration.commandName, "show")
    }

    func testSearchCommandName() {
        XCTAssertEqual(NotesCommand.Search.configuration.commandName, "search")
    }

    func testFoldersCommandName() {
        XCTAssertEqual(NotesCommand.Folders.configuration.commandName, "folders")
    }

    func testCreateCommandName() {
        XCTAssertEqual(NotesCommand.Create.configuration.commandName, "create")
    }

    func testEditCommandName() {
        XCTAssertEqual(NotesCommand.Edit.configuration.commandName, "edit")
    }

    func testDeleteCommandName() {
        XCTAssertEqual(NotesCommand.Delete.configuration.commandName, "delete")
    }

    // MARK: - List subcommand

    func testListNoArgsPasses() {
        XCTAssertNoThrow(try NotesCommand.List.parse([]))
    }

    func testListFolderOptionPasses() throws {
        let cmd = try NotesCommand.List.parse(["--folder", "Work"])
        XCTAssertEqual(cmd.folder, "Work")
    }

    func testListLimitOptionPasses() throws {
        let cmd = try NotesCommand.List.parse(["--limit", "20"])
        XCTAssertEqual(cmd.limit, 20)
    }

    func testListDefaultLimitIs50() throws {
        let cmd = try NotesCommand.List.parse([])
        XCTAssertEqual(cmd.limit, 50)
    }

    func testListZeroLimitFails() {
        XCTAssertThrowsError(try NotesCommand.List.parse(["--limit", "0"]))
    }

    func testListFieldsOptionPasses() throws {
        let cmd = try NotesCommand.List.parse(["--fields", "id,title"])
        XCTAssertEqual(cmd.fields, "id,title")
    }

    func testListJsonFormatPasses() {
        XCTAssertNoThrow(try NotesCommand.List.parse(["--format", "json"]))
    }

    // MARK: - Show subcommand

    func testShowRequiresId() {
        XCTAssertThrowsError(try NotesCommand.Show.parse([]))
    }

    func testShowWithIdPasses() {
        XCTAssertNoThrow(try NotesCommand.Show.parse(["x-coredata://abc/ICNote/p1"]))
    }

    func testShowParsesId() throws {
        let cmd = try NotesCommand.Show.parse(["x-coredata://abc/ICNote/p1"])
        XCTAssertEqual(cmd.id, "x-coredata://abc/ICNote/p1")
    }

    func testShowJsonFormatPasses() {
        XCTAssertNoThrow(try NotesCommand.Show.parse(["some-id", "--format", "json"]))
    }

    // MARK: - Search subcommand

    func testSearchRequiresQuery() {
        XCTAssertThrowsError(try NotesCommand.Search.parse([]))
    }

    func testSearchWithQueryPasses() {
        XCTAssertNoThrow(try NotesCommand.Search.parse(["meeting notes"]))
    }

    func testSearchParsesQuery() throws {
        let cmd = try NotesCommand.Search.parse(["groceries"])
        XCTAssertEqual(cmd.query, "groceries")
    }

    func testSearchFolderOptionPasses() throws {
        let cmd = try NotesCommand.Search.parse(["query", "--folder", "Work"])
        XCTAssertEqual(cmd.folder, "Work")
    }

    func testSearchLimitOptionPasses() throws {
        let cmd = try NotesCommand.Search.parse(["query", "--limit", "15"])
        XCTAssertEqual(cmd.limit, 15)
    }

    func testSearchDefaultLimitIs50() throws {
        let cmd = try NotesCommand.Search.parse(["query"])
        XCTAssertEqual(cmd.limit, 50)
    }

    func testSearchZeroLimitFails() {
        XCTAssertThrowsError(try NotesCommand.Search.parse(["query", "--limit", "0"]))
    }

    func testSearchFieldsOptionPasses() throws {
        let cmd = try NotesCommand.Search.parse(["query", "--fields", "id,title,folder"])
        XCTAssertEqual(cmd.fields, "id,title,folder")
    }

    func testSearchJsonFormatPasses() {
        XCTAssertNoThrow(try NotesCommand.Search.parse(["query", "--format", "json"]))
    }

    // MARK: - Folders subcommand

    func testFoldersNoArgsPasses() {
        XCTAssertNoThrow(try NotesCommand.Folders.parse([]))
    }

    func testFoldersJsonFormatPasses() {
        XCTAssertNoThrow(try NotesCommand.Folders.parse(["--format", "json"]))
    }

    // MARK: - Create subcommand

    func testCreateRequiresTitle() {
        XCTAssertThrowsError(try NotesCommand.Create.parse([]))
    }

    func testCreateWithTitlePasses() {
        XCTAssertNoThrow(try NotesCommand.Create.parse(["My Note"]))
    }

    func testCreateParsesTitle() throws {
        let cmd = try NotesCommand.Create.parse(["Shopping List"])
        XCTAssertEqual(cmd.title, "Shopping List")
    }

    func testCreateFolderOptionPasses() throws {
        let cmd = try NotesCommand.Create.parse(["Note Title", "--folder", "Work"])
        XCTAssertEqual(cmd.folder, "Work")
    }

    func testCreateBodyOptionPasses() throws {
        let cmd = try NotesCommand.Create.parse(["Note Title", "--body", "Some content"])
        XCTAssertEqual(cmd.body, "Some content")
    }

    func testCreateJsonFormatPasses() {
        XCTAssertNoThrow(try NotesCommand.Create.parse(["Note Title", "--format", "json"]))
    }

    func testCreateWithAllOptionsPasses() {
        XCTAssertNoThrow(try NotesCommand.Create.parse([
            "My Note",
            "--folder", "Work",
            "--body", "Note content here",
            "--format", "json",
        ]))
    }

    // MARK: - Edit subcommand

    func testEditRequiresId() {
        XCTAssertThrowsError(try NotesCommand.Edit.parse([]))
    }

    func testEditIdWithoutTitleOrBodyFails() {
        XCTAssertThrowsError(try NotesCommand.Edit.parse(["note-id"]))
    }

    func testEditIdWithTitlePasses() {
        XCTAssertNoThrow(try NotesCommand.Edit.parse(["note-id", "--title", "New Title"]))
    }

    func testEditIdWithBodyPasses() {
        XCTAssertNoThrow(try NotesCommand.Edit.parse(["note-id", "--body", "New body content"]))
    }

    func testEditAppendFlagPasses() throws {
        let cmd = try NotesCommand.Edit.parse(["note-id", "--body", "extra content", "--append"])
        XCTAssertTrue(cmd.append)
    }

    func testEditAppendDefaultFalse() throws {
        let cmd = try NotesCommand.Edit.parse(["note-id", "--title", "New Title"])
        XCTAssertFalse(cmd.append)
    }

    func testEditJsonFormatPasses() {
        XCTAssertNoThrow(try NotesCommand.Edit.parse(["note-id", "--title", "Title", "--format", "json"]))
    }

    // MARK: - Delete subcommand

    func testDeleteRequiresId() {
        XCTAssertThrowsError(try NotesCommand.Delete.parse([]))
    }

    func testDeleteWithoutForceFails() {
        XCTAssertThrowsError(try NotesCommand.Delete.parse(["note-id"]))
    }

    func testDeleteWithForcePasses() {
        XCTAssertNoThrow(try NotesCommand.Delete.parse(["note-id", "--force"]))
    }

    func testDeleteWithForceAndJsonPasses() {
        XCTAssertNoThrow(try NotesCommand.Delete.parse(["note-id", "--force", "--format", "json"]))
    }

    func testDeleteParsesId() throws {
        let cmd = try NotesCommand.Delete.parse(["x-coredata://abc/ICNote/p5", "--force"])
        XCTAssertEqual(cmd.id, "x-coredata://abc/ICNote/p5")
    }
}
