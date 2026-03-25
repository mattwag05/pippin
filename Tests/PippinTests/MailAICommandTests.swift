@testable import PippinLib
import XCTest

final class MailAICommandTests: XCTestCase {
    func testIndexSubcommandRegistered() throws {
        let subcommands = MailCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("index"), "Expected 'index' in subcommands, got: \(names)")
    }

    func testIndexDefaultLimit() throws {
        let cmd = try MailCommand.Index.parse([])
        XCTAssertEqual(cmd.limit, 500)
    }

    func testIndexCustomLimit() throws {
        let cmd = try MailCommand.Index.parse(["--limit", "50"])
        XCTAssertEqual(cmd.limit, 50)
    }

    func testIndexDefaultProvider() throws {
        let cmd = try MailCommand.Index.parse([])
        XCTAssertEqual(cmd.provider, "ollama")
    }

    func testIndexDefaultMailbox() throws {
        let cmd = try MailCommand.Index.parse([])
        XCTAssertEqual(cmd.mailbox, "INBOX")
    }

    func testIndexAcceptsFormat() throws {
        XCTAssertNoThrow(try MailCommand.Index.parse(["--format", "json"]))
    }

    func testIndexAcceptsAccount() throws {
        XCTAssertNoThrow(try MailCommand.Index.parse(["--account", "me@example.com"]))
    }

    // MARK: - Phase 2 tests

    func testSanitizeSubcommandRegistered() throws {
        let subcommands = MailCommand.configuration.subcommands
        let names = subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("sanitize"), "Expected 'sanitize' in subcommands, got: \(names)")
    }

    func testSanitizeParsesWithMessageId() throws {
        let cmd = try MailCommand.Sanitize.parse(["msg123"])
        XCTAssertEqual(cmd.messageId, "msg123")
    }

    func testSanitizeAiAssistedFlagDefault() throws {
        let cmd = try MailCommand.Sanitize.parse(["msg123"])
        XCTAssertFalse(cmd.aiAssisted, "ai-assisted should default to false")
    }

    func testSanitizeAcceptsFormat() throws {
        XCTAssertNoThrow(try MailCommand.Sanitize.parse(["msg123", "--format", "json"]))
    }

    func testShowSanitizeFlagDefault() throws {
        let cmd = try MailCommand.Show.parse(["msg123"])
        XCTAssertFalse(cmd.sanitize, "sanitize should default to false")
    }
}
