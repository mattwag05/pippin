import XCTest
@testable import PippinLib

/// Tests for ArgumentParser `validate()` logic in MailCommand subcommands.
///
/// Using `SubCommand.parse([...])` rather than constructing structs directly:
/// ArgumentParser property wrappers require the parser to have run before any
/// property is accessed; `init()` bypasses this and causes a runtime crash.
/// `parse()` goes through the full initialization + `validate()` call.
final class MailCommandValidationTests: XCTestCase {

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

    // MARK: - Send email address validation

    func testSendValidToPasses() {
        XCTAssertNoThrow(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body"
        ]))
    }

    func testSendNoAtSignFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--to", "notanemail", "--subject", "Test", "--body", "Body"
        ]))
    }

    func testSendNoDomainFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--to", "user@", "--subject", "Test", "--body", "Body"
        ]))
    }

    func testSendValidCCPasses() {
        XCTAssertNoThrow(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--cc", "cc@example.com"
        ]))
    }

    func testSendInvalidCCFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--cc", "notanemail"
        ]))
    }

    // MARK: - Send attachment file existence

    func testSendNonexistentAttachmentFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--attach", "/tmp/pippin-test-nonexistent-\(UUID().uuidString).txt"
        ]))
    }

    func testSendExistingAttachmentPasses() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pippin-test-attach-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmpURL.path, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        XCTAssertNoThrow(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--attach", tmpURL.path
        ]))
    }
}
