@testable import PippinLib
import XCTest

/// Tests for ArgumentParser `validate()` logic in MailCommand subcommands.
///
/// Using `SubCommand.parse([...])` rather than constructing structs directly:
/// ArgumentParser property wrappers require the parser to have run before any
/// property is accessed; `init()` bypasses this and causes a runtime crash.
/// `parse()` goes through the full initialization + `validate()` call.
final class MailCommandValidationTests: XCTestCase {
    // MARK: - Show command (messageId vs --subject)

    func testShowWithMessageIdPasses() {
        XCTAssertNoThrow(try MailCommand.Show.parse(["some-id"]))
    }

    func testShowWithSubjectPasses() {
        XCTAssertNoThrow(try MailCommand.Show.parse(["--subject", "Test email"]))
    }

    func testShowWithBothFails() {
        XCTAssertThrowsError(try MailCommand.Show.parse(["some-id", "--subject", "Test"]))
    }

    func testShowWithNeitherFails() {
        XCTAssertThrowsError(try MailCommand.Show.parse([]))
    }

    func testShowWithJsonFormat() throws {
        let cmd = try MailCommand.Show.parse(["some-id", "--format", "json"])
        XCTAssertTrue(cmd.output.isJSON)
    }

    func testShowWithTextFormat() throws {
        let cmd = try MailCommand.Show.parse(["some-id", "--format", "text"])
        XCTAssertFalse(cmd.output.isJSON)
    }

    func testShowDefaultsToText() throws {
        let cmd = try MailCommand.Show.parse(["some-id"])
        XCTAssertFalse(cmd.output.isJSON)
    }

    // MARK: - Read alias (hidden, delegates to Show)

    func testReadAliasParses() {
        XCTAssertNoThrow(try MailCommand.Read.parse(["some-id"]))
    }

    func testReadAliasIsHidden() {
        XCTAssertFalse(MailCommand.Read.configuration.shouldDisplay)
    }

    // MARK: - Mark mutual exclusivity

    func testMarkNeitherFlagFails() {
        // No --read or --unread: validate() should throw
        XCTAssertThrowsError(try MailCommand.Mark.parse(["some-id"]))
    }

    func testMarkBothFlagsFails() {
        XCTAssertThrowsError(try MailCommand.Mark.parse(["some-id", "--read", "--unread"]))
    }

    func testMarkReadOnlyPasses() {
        XCTAssertNoThrow(try MailCommand.Mark.parse(["some-id", "--read"]))
    }

    func testMarkUnreadOnlyPasses() {
        XCTAssertNoThrow(try MailCommand.Mark.parse(["some-id", "--unread"]))
    }

    // MARK: - List defaults

    func testListDefaultLimit() throws {
        let cmd = try MailCommand.List.parse([])
        XCTAssertEqual(cmd.limit, 20)
    }

    func testListCustomLimit() throws {
        let cmd = try MailCommand.List.parse(["--limit", "5"])
        XCTAssertEqual(cmd.limit, 5)
    }

    // MARK: - Send email address validation

    func testSendValidToPasses() {
        XCTAssertNoThrow(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
        ]))
    }

    func testSendNoAtSignFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--to", "notanemail", "--subject", "Test", "--body", "Body",
        ]))
    }

    func testSendNoDomainFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--to", "user@", "--subject", "Test", "--body", "Body",
        ]))
    }

    func testSendValidCCPasses() {
        XCTAssertNoThrow(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--cc", "cc@example.com",
        ]))
    }

    func testSendInvalidCCFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--cc", "notanemail",
        ]))
    }

    // MARK: - Send attachment file existence

    func testSendNonexistentAttachmentFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--attach", "/tmp/pippin-test-nonexistent-\(UUID().uuidString).txt",
        ]))
    }

    func testSendExistingAttachmentPasses() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pippin-test-attach-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmpURL.path, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        XCTAssertNoThrow(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--attach", tmpURL.path,
        ]))
    }

    // MARK: - Output format on all subcommands

    func testAccountsAcceptsFormat() {
        XCTAssertNoThrow(try MailCommand.Accounts.parse(["--format", "json"]))
    }

    func testSearchAcceptsFormat() {
        XCTAssertNoThrow(try MailCommand.Search.parse(["query", "--format", "json"]))
    }

    func testListAcceptsFormat() {
        XCTAssertNoThrow(try MailCommand.List.parse(["--format", "json"]))
    }

    func testMarkAcceptsFormat() {
        XCTAssertNoThrow(try MailCommand.Mark.parse(["some-id", "--read", "--format", "json"]))
    }

    func testMoveAcceptsFormat() {
        XCTAssertNoThrow(try MailCommand.Move.parse(["some-id", "--to", "Archive", "--format", "json"]))
    }

    func testSendAcceptsFormat() {
        XCTAssertNoThrow(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--format", "json",
        ]))
    }
}
