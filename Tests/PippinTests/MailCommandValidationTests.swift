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

    func testSendMultipleToAddresses() throws {
        let cmd = try MailCommand.Send.parse([
            "--to", "a@example.com", "--to", "b@example.com",
            "--subject", "Test", "--body", "Body",
        ])
        XCTAssertEqual(cmd.to, ["a@example.com", "b@example.com"])
    }

    func testSendMissingToFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--subject", "Test", "--body", "Body",
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

    func testSendBCCPasses() throws {
        let cmd = try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--bcc", "hidden@example.com",
        ])
        XCTAssertEqual(cmd.bcc, ["hidden@example.com"])
    }

    func testSendInvalidBCCFails() {
        XCTAssertThrowsError(try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--bcc", "notanemail",
        ]))
    }

    func testSendMultipleBCC() throws {
        let cmd = try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--bcc", "a@example.com", "--bcc", "b@example.com",
        ])
        XCTAssertEqual(cmd.bcc, ["a@example.com", "b@example.com"])
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

    func testSendMultipleAttachmentsPasses() throws {
        let tmp1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("pippin-test-att1-\(UUID().uuidString).txt")
        let tmp2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("pippin-test-att2-\(UUID().uuidString).pdf")
        FileManager.default.createFile(atPath: tmp1.path, contents: Data("a".utf8))
        FileManager.default.createFile(atPath: tmp2.path, contents: Data("b".utf8))
        defer {
            try? FileManager.default.removeItem(at: tmp1)
            try? FileManager.default.removeItem(at: tmp2)
        }
        let cmd = try MailCommand.Send.parse([
            "--to", "user@example.com", "--subject", "Test", "--body", "Body",
            "--attach", tmp1.path, "--attach", tmp2.path,
        ])
        XCTAssertEqual(cmd.attach.count, 2)
    }

    // MARK: - Attachments subcommand

    func testAttachmentsParsesPasses() {
        XCTAssertNoThrow(try MailCommand.Attachments.parse(["some-id"]))
    }

    func testAttachmentsSaveDirNonexistentFails() {
        XCTAssertThrowsError(try MailCommand.Attachments.parse([
            "some-id", "--save-dir", "/tmp/pippin-nonexistent-dir-\(UUID().uuidString)",
        ]))
    }

    func testAttachmentsSaveDirExistingPasses() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pippin-test-savedir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try MailCommand.Attachments.parse(["some-id", "--save-dir", dir.path]))
    }

    // MARK: - Reply subcommand

    func testReplyParsesWithBody() {
        XCTAssertNoThrow(try MailCommand.Reply.parse(["some-id", "--body", "Thanks!"]))
    }

    func testReplyWithOptionalTo() throws {
        let cmd = try MailCommand.Reply.parse(["some-id", "--body", "OK", "--to", "other@example.com"])
        XCTAssertEqual(cmd.to, ["other@example.com"])
    }

    func testReplyInvalidToFails() {
        XCTAssertThrowsError(try MailCommand.Reply.parse(["some-id", "--body", "OK", "--to", "notanemail"]))
    }

    func testReplyDefaultToIsEmpty() throws {
        let cmd = try MailCommand.Reply.parse(["some-id", "--body", "OK"])
        XCTAssertTrue(cmd.to.isEmpty)
    }

    // MARK: - Forward subcommand

    func testForwardParsesWithTo() {
        XCTAssertNoThrow(try MailCommand.Forward.parse(["some-id", "--to", "fwd@example.com"]))
    }

    func testForwardMissingToFails() {
        XCTAssertThrowsError(try MailCommand.Forward.parse(["some-id"]))
    }

    func testForwardInvalidToFails() {
        XCTAssertThrowsError(try MailCommand.Forward.parse(["some-id", "--to", "notanemail"]))
    }

    func testForwardWithOptionalBody() throws {
        let cmd = try MailCommand.Forward.parse(["some-id", "--to", "fwd@example.com", "--body", "FYI"])
        XCTAssertEqual(cmd.body, "FYI")
    }

    func testForwardDefaultBodyIsEmpty() throws {
        let cmd = try MailCommand.Forward.parse(["some-id", "--to", "fwd@example.com"])
        XCTAssertEqual(cmd.body, "")
    }

    // MARK: - Mailboxes subcommand

    func testMailboxesParsesWithNoArgs() {
        XCTAssertNoThrow(try MailCommand.Mailboxes.parse([]))
    }

    func testMailboxesParsesWithAccount() throws {
        let cmd = try MailCommand.Mailboxes.parse(["--account", "Work"])
        XCTAssertEqual(cmd.account, "Work")
    }

    func testMailboxesAcceptsFormat() {
        XCTAssertNoThrow(try MailCommand.Mailboxes.parse(["--format", "json"]))
    }

    // MARK: - List --page

    func testListPageDefault() throws {
        let cmd = try MailCommand.List.parse([])
        XCTAssertEqual(cmd.page, 1)
    }

    func testListPageCustom() throws {
        let cmd = try MailCommand.List.parse(["--page", "3"])
        XCTAssertEqual(cmd.page, 3)
    }

    func testListPageZeroFails() {
        XCTAssertThrowsError(try MailCommand.List.parse(["--page", "0"]))
    }

    // MARK: - List --preview

    func testListPreviewDefaultIsNil() throws {
        let cmd = try MailCommand.List.parse([])
        XCTAssertNil(cmd.preview)
    }

    func testListPreviewValidPasses() throws {
        let cmd = try MailCommand.List.parse(["--preview", "200"])
        XCTAssertEqual(cmd.preview, 200)
    }

    func testListPreviewZeroFails() {
        XCTAssertThrowsError(try MailCommand.List.parse(["--preview", "0"]))
    }

    func testListPreviewNegativeFails() {
        XCTAssertThrowsError(try MailCommand.List.parse(["--preview", "-1"]))
    }

    // MARK: - List pagination flags (pippin-gb3)

    func testListParsesPageSize() throws {
        let cmd = try MailCommand.List.parse(["--page-size", "10"])
        XCTAssertEqual(cmd.pagination.pageSize, 10)
        XCTAssertTrue(cmd.pagination.isActive)
    }

    func testListParsesCursor() throws {
        let token = try Pagination.encode(Cursor(offset: 5, filterHash: "abc"))
        let cmd = try MailCommand.List.parse(["--cursor", token])
        XCTAssertEqual(cmd.pagination.cursor, token)
    }

    func testListPaginationInactiveByDefault() throws {
        let cmd = try MailCommand.List.parse([])
        XCTAssertFalse(cmd.pagination.isActive)
    }

    func testListSummarizeWithPaginationFails() {
        // ArgumentParser runs validate() during parse(), so the throw surfaces here.
        XCTAssertThrowsError(try MailCommand.List.parse(["--page-size", "10", "--summarize"]))
    }

    // MARK: - Search --page

    func testSearchPageDefault() throws {
        let cmd = try MailCommand.Search.parse(["invoice"])
        XCTAssertEqual(cmd.page, 1)
    }

    func testSearchPageCustom() throws {
        let cmd = try MailCommand.Search.parse(["invoice", "--page", "2"])
        XCTAssertEqual(cmd.page, 2)
    }

    func testSearchPageZeroFails() {
        XCTAssertThrowsError(try MailCommand.Search.parse(["invoice", "--page", "0"]))
    }

    // MARK: - Search pagination flags (pippin-a9m)

    func testSearchParsesPageSize() throws {
        let cmd = try MailCommand.Search.parse(["invoice", "--page-size", "7"])
        XCTAssertEqual(cmd.pagination.pageSize, 7)
        XCTAssertTrue(cmd.pagination.isActive)
    }

    func testSearchParsesCursor() throws {
        let token = try Pagination.encode(Cursor(offset: 12, filterHash: "deadbeef"))
        let cmd = try MailCommand.Search.parse(["invoice", "--cursor", token])
        XCTAssertEqual(cmd.pagination.cursor, token)
    }

    func testSearchPaginationInactiveByDefault() throws {
        let cmd = try MailCommand.Search.parse(["invoice"])
        XCTAssertFalse(cmd.pagination.isActive)
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

    // MARK: - Search --after / --before date validation

    func testSearchAfterDateValidPasses() {
        XCTAssertNoThrow(try MailCommand.Search.parse(["query", "--after", "2026-03-07"]))
    }

    func testSearchAfterDateInvalidFails() {
        XCTAssertThrowsError(try MailCommand.Search.parse(["query", "--after", "03/07/2026"]))
    }

    func testSearchAfterDateBadCalendarFails() {
        XCTAssertThrowsError(try MailCommand.Search.parse(["query", "--after", "2026-13-01"]))
    }

    func testSearchBeforeDateValidPasses() {
        XCTAssertNoThrow(try MailCommand.Search.parse(["query", "--before", "2026-03-10"]))
    }

    func testSearchBeforeAndAfterBothValidPass() {
        XCTAssertNoThrow(try MailCommand.Search.parse(["query", "--after", "2026-03-07", "--before", "2026-03-10"]))
    }

    // MARK: - Search --to filter

    func testSearchToFilterPasses() throws {
        let cmd = try MailCommand.Search.parse(["query", "--to", "user@example.com"])
        XCTAssertEqual(cmd.to, "user@example.com")
    }

    func testSearchToFilterNilByDefault() throws {
        let cmd = try MailCommand.Search.parse(["query"])
        XCTAssertNil(cmd.to)
    }

    // MARK: - Search --verbose flag

    func testSearchVerboseFlagPasses() throws {
        let cmd = try MailCommand.Search.parse(["query", "--verbose"])
        XCTAssertTrue(cmd.verbose)
    }

    func testSearchVerboseDefaultsFalse() throws {
        let cmd = try MailCommand.Search.parse(["query"])
        XCTAssertFalse(cmd.verbose)
    }
}
