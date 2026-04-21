@testable import PippinLib
import XCTest

final class JobCommandTests: XCTestCase {
    // MARK: - Configuration

    func testJobCommandName() {
        XCTAssertEqual(JobCommand.configuration.commandName, "job")
    }

    func testSubcommandsRegistered() {
        let names = JobCommand.configuration.subcommands.compactMap { $0.configuration.commandName }
        XCTAssertEqual(names.sorted(), ["gc", "list", "logs", "run", "show", "wait"])
    }

    func testRunnerInternalHidden() {
        XCTAssertFalse(JobRunnerInternalCommand.configuration.shouldDisplay)
        XCTAssertEqual(JobRunnerInternalCommand.configuration.commandName, "job-runner-internal")
    }

    // MARK: - Run parsing

    func testRunRequiresArgv() {
        XCTAssertThrowsError(try JobCommand.Run.parse([]))
    }

    func testRunCapturesArgvAfterTerminator() throws {
        let cmd = try JobCommand.Run.parse(["--", "mail", "index"])
        XCTAssertEqual(cmd.argv, ["mail", "index"])
    }

    func testRunCapturesArgvWithEmbeddedFlags() throws {
        let cmd = try JobCommand.Run.parse(["--", "memos", "summarize", "abc", "--provider", "ollama"])
        XCTAssertEqual(cmd.argv, ["memos", "summarize", "abc", "--provider", "ollama"])
    }

    // MARK: - Show parsing

    func testShowRequiresId() {
        XCTAssertThrowsError(try JobCommand.Show.parse([]))
    }

    func testShowDefaultTail() throws {
        let cmd = try JobCommand.Show.parse(["jobid"])
        XCTAssertEqual(cmd.tail, 4096)
    }

    func testShowCustomTail() throws {
        let cmd = try JobCommand.Show.parse(["jobid", "--tail", "500"])
        XCTAssertEqual(cmd.tail, 500)
    }

    // MARK: - List parsing

    func testListLimitZeroFails() {
        XCTAssertThrowsError(try JobCommand.List.parse(["--limit", "0"]))
    }

    func testListStatusFilter() throws {
        let cmd = try JobCommand.List.parse(["--status", "running"])
        XCTAssertEqual(cmd.status, "running")
    }

    func testListInvalidStatusFails() {
        XCTAssertThrowsError(try JobCommand.List.parse(["--status", "frobnicated"]))
    }

    // MARK: - Wait parsing

    func testWaitRequiresId() {
        XCTAssertThrowsError(try JobCommand.Wait.parse([]))
    }

    func testWaitDefaults() throws {
        let cmd = try JobCommand.Wait.parse(["jobid"])
        XCTAssertEqual(cmd.timeout, 300)
        XCTAssertEqual(cmd.pollMs, 200)
    }

    func testWaitCustomTimeout() throws {
        let cmd = try JobCommand.Wait.parse(["jobid", "--timeout", "30"])
        XCTAssertEqual(cmd.timeout, 30)
    }

    // MARK: - Logs parsing

    func testLogsStreamFlag() throws {
        let cmd = try JobCommand.Logs.parse(["jobid", "--stream"])
        XCTAssertTrue(cmd.stream)
    }

    func testLogsStderrFlag() throws {
        let cmd = try JobCommand.Logs.parse(["jobid", "--stderr"])
        XCTAssertTrue(cmd.stderr)
    }

    // MARK: - Gc parsing

    func testGcDefault() throws {
        let cmd = try JobCommand.Gc.parse([])
        XCTAssertEqual(cmd.olderThan, "7d")
    }

    func testGcCustomDuration() throws {
        let cmd = try JobCommand.Gc.parse(["--older-than", "30d"])
        XCTAssertEqual(cmd.olderThan, "30d")
    }

    // MARK: - parseDuration

    func testParseDurationSeconds() throws {
        XCTAssertEqual(try parseDuration("30s"), 30)
    }

    func testParseDurationMinutes() throws {
        XCTAssertEqual(try parseDuration("5m"), 300)
    }

    func testParseDurationHours() throws {
        XCTAssertEqual(try parseDuration("2h"), 7200)
    }

    func testParseDurationDays() throws {
        XCTAssertEqual(try parseDuration("7d"), 7 * 86400)
    }

    func testParseDurationWeeks() throws {
        XCTAssertEqual(try parseDuration("2w"), 14 * 86400)
    }

    func testParseDurationInvalidUnitThrows() {
        XCTAssertThrowsError(try parseDuration("5x"))
    }

    func testParseDurationNonNumericThrows() {
        XCTAssertThrowsError(try parseDuration("abc"))
    }

    func testParseDurationNegativeThrows() {
        XCTAssertThrowsError(try parseDuration("-1d"))
    }
}
