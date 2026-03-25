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
}
