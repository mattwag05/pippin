@testable import PippinLib
import XCTest

final class ShellCommandTests: XCTestCase {
    // MARK: - Shell Argument Splitting

    func testShellSplitSimple() {
        XCTAssertEqual(shellSplit("mail accounts"), ["mail", "accounts"])
    }

    func testShellSplitWithFlags() {
        XCTAssertEqual(
            shellSplit("mail list --account Work --format json"),
            ["mail", "list", "--account", "Work", "--format", "json"]
        )
    }

    func testShellSplitDoubleQuotes() {
        XCTAssertEqual(
            shellSplit("mail search \"hello world\""),
            ["mail", "search", "hello world"]
        )
    }

    func testShellSplitSingleQuotes() {
        XCTAssertEqual(
            shellSplit("mail search 'hello world'"),
            ["mail", "search", "hello world"]
        )
    }

    func testShellSplitEmpty() {
        XCTAssertEqual(shellSplit(""), [])
    }

    func testShellSplitWhitespace() {
        XCTAssertEqual(shellSplit("   mail    accounts   "), ["mail", "accounts"])
    }

    func testShellSplitMixedQuotes() {
        XCTAssertEqual(
            shellSplit("mail send --to \"a@b.com\" --subject 'Hello World'"),
            ["mail", "send", "--to", "a@b.com", "--subject", "Hello World"]
        )
    }

    func testShellSplitEqualsFlag() {
        XCTAssertEqual(
            shellSplit("mail list --format=json"),
            ["mail", "list", "--format=json"]
        )
    }

    // MARK: - ShellCommand Configuration

    func testShellCommandName() {
        XCTAssertEqual(ShellCommand.configuration.commandName, "shell")
    }

    func testShellCommandAbstract() {
        XCTAssertNotNil(ShellCommand.configuration.abstract)
        XCTAssertFalse(ShellCommand.configuration.abstract.isEmpty)
    }

    func testShellCommandParses() throws {
        // Verify the command can be created with no arguments
        let command = try ShellCommand.parse([])
        XCTAssertNil(command.format)
    }

    func testShellCommandParsesWithFormat() throws {
        let command = try ShellCommand.parse(["--format", "json"])
        XCTAssertEqual(command.format, .json)
    }

    func testShellCommandParsesAgentFormat() throws {
        let command = try ShellCommand.parse(["--format", "agent"])
        XCTAssertEqual(command.format, .agent)
    }
}
