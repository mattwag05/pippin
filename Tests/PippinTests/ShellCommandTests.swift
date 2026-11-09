@testable import PippinLib
import XCTest

final class ShellCommandTests: XCTestCase {
    // MARK: - Shell Argument Splitting

    func testShellSplitSimple() {
        XCTAssertEqual(shellSplit("mail accounts"), ["mail", "accounts"])
    }

    func testShellSplitWithFlags() {
        XCTAssertEqual(
            shellSplit("mail list --account Work --format agent"),
            ["mail", "list", "--account", "Work", "--format", "agent"]
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
            shellSplit("mail list --format=agent"),
            ["mail", "list", "--format=agent"]
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
        XCTAssertNoThrow(try ShellCommand.parse([]))
    }

    func testShellCommandRejectsFormatFlag() {
        XCTAssertThrowsError(try ShellCommand.parse(["--format", "agent"]))
    }
}
