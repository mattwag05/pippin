@testable import PippinLib
import XCTest

final class BrowserCommandTests: XCTestCase {
    // MARK: - BrowserCommand Configuration

    func testBrowserCommandName() {
        XCTAssertEqual(BrowserCommand.configuration.commandName, "browser")
    }

    func testBrowserSubcommandCount() {
        let subcommands = BrowserCommand.configuration.subcommands
        XCTAssertEqual(subcommands.count, 9)
    }

    // MARK: - Subcommand Names

    func testOpenCommandName() {
        XCTAssertEqual(BrowserCommand.Open.configuration.commandName, "open")
    }

    func testSnapshotCommandName() {
        XCTAssertEqual(BrowserCommand.Snapshot.configuration.commandName, "snapshot")
    }

    func testScreenshotCommandName() {
        XCTAssertEqual(BrowserCommand.Screenshot.configuration.commandName, "screenshot")
    }

    func testClickCommandName() {
        XCTAssertEqual(BrowserCommand.Click.configuration.commandName, "click")
    }

    func testFillCommandName() {
        XCTAssertEqual(BrowserCommand.Fill.configuration.commandName, "fill")
    }

    func testScrollCommandName() {
        XCTAssertEqual(BrowserCommand.Scroll.configuration.commandName, "scroll")
    }

    func testTabsCommandName() {
        XCTAssertEqual(BrowserCommand.Tabs.configuration.commandName, "tabs")
    }

    func testCloseCommandName() {
        XCTAssertEqual(BrowserCommand.Close.configuration.commandName, "close")
    }

    func testFetchCommandName() {
        XCTAssertEqual(BrowserCommand.Fetch.configuration.commandName, "fetch")
    }

    // MARK: - BrowserCommand.Open Parse Tests

    func testOpenParsesWithURL() {
        XCTAssertNoThrow(try BrowserCommand.Open.parse(["https://example.com"]))
    }

    func testOpenFailsWithoutURL() {
        XCTAssertThrowsError(try BrowserCommand.Open.parse([]))
    }

    func testOpenParsesURL() throws {
        let cmd = try BrowserCommand.Open.parse(["https://example.com"])
        XCTAssertEqual(cmd.url, "https://example.com")
    }

    func testOpenSessionDirDefaultsToNil() throws {
        let cmd = try BrowserCommand.Open.parse(["https://example.com"])
        XCTAssertNil(cmd.sessionDir)
    }

    func testOpenParsesSessionDir() throws {
        let cmd = try BrowserCommand.Open.parse(["https://example.com", "--session-dir", "/tmp/session"])
        XCTAssertEqual(cmd.sessionDir, "/tmp/session")
    }

    // MARK: - BrowserCommand.Snapshot Parse Tests

    func testSnapshotParsesWithNoArgs() {
        XCTAssertNoThrow(try BrowserCommand.Snapshot.parse([]))
    }

    func testSnapshotSessionDirDefaultsToNil() throws {
        let cmd = try BrowserCommand.Snapshot.parse([])
        XCTAssertNil(cmd.sessionDir)
    }

    func testSnapshotParsesSessionDir() throws {
        let cmd = try BrowserCommand.Snapshot.parse(["--session-dir", "/tmp/session"])
        XCTAssertEqual(cmd.sessionDir, "/tmp/session")
    }

    // MARK: - BrowserCommand.Screenshot Parse Tests

    func testScreenshotParsesWithNoArgs() {
        XCTAssertNoThrow(try BrowserCommand.Screenshot.parse([]))
    }

    func testScreenshotFileDefault() throws {
        let cmd = try BrowserCommand.Screenshot.parse([])
        XCTAssertEqual(cmd.file, "screenshot.png")
    }

    func testScreenshotParsesCustomFile() throws {
        let cmd = try BrowserCommand.Screenshot.parse(["--file", "output.png"])
        XCTAssertEqual(cmd.file, "output.png")
    }

    func testScreenshotSessionDirDefaultsToNil() throws {
        let cmd = try BrowserCommand.Screenshot.parse([])
        XCTAssertNil(cmd.sessionDir)
    }

    func testScreenshotParsesSessionDir() throws {
        let cmd = try BrowserCommand.Screenshot.parse(["--session-dir", "/tmp/session"])
        XCTAssertEqual(cmd.sessionDir, "/tmp/session")
    }

    // MARK: - BrowserCommand.Click Parse Tests

    func testClickParsesWithRef() {
        XCTAssertNoThrow(try BrowserCommand.Click.parse(["@ref1"]))
    }

    func testClickFailsWithoutRef() {
        XCTAssertThrowsError(try BrowserCommand.Click.parse([]))
    }

    func testClickParsesRef() throws {
        let cmd = try BrowserCommand.Click.parse(["@ref1"])
        XCTAssertEqual(cmd.ref, "@ref1")
    }

    func testClickSessionDirDefaultsToNil() throws {
        let cmd = try BrowserCommand.Click.parse(["@ref1"])
        XCTAssertNil(cmd.sessionDir)
    }

    func testClickParsesSessionDir() throws {
        let cmd = try BrowserCommand.Click.parse(["@ref1", "--session-dir", "/tmp/session"])
        XCTAssertEqual(cmd.sessionDir, "/tmp/session")
    }

    // MARK: - BrowserCommand.Fill Parse Tests

    func testFillParsesWithRefAndValue() {
        XCTAssertNoThrow(try BrowserCommand.Fill.parse(["@ref2", "hello"]))
    }

    func testFillFailsWithoutArgs() {
        XCTAssertThrowsError(try BrowserCommand.Fill.parse([]))
    }

    func testFillFailsWithOnlyRef() {
        XCTAssertThrowsError(try BrowserCommand.Fill.parse(["@ref2"]))
    }

    func testFillParsesRefAndValue() throws {
        let cmd = try BrowserCommand.Fill.parse(["@ref2", "hello world"])
        XCTAssertEqual(cmd.ref, "@ref2")
        XCTAssertEqual(cmd.value, "hello world")
    }

    func testFillSessionDirDefaultsToNil() throws {
        let cmd = try BrowserCommand.Fill.parse(["@ref2", "hello"])
        XCTAssertNil(cmd.sessionDir)
    }

    // MARK: - BrowserCommand.Scroll Parse Tests

    func testScrollParsesWithDirection() {
        XCTAssertNoThrow(try BrowserCommand.Scroll.parse(["down"]))
    }

    func testScrollFailsWithoutDirection() {
        XCTAssertThrowsError(try BrowserCommand.Scroll.parse([]))
    }

    func testScrollParsesDirection() throws {
        let cmd = try BrowserCommand.Scroll.parse(["down"])
        XCTAssertEqual(cmd.direction, "down")
    }

    func testScrollParsesAnyStringDirection() throws {
        // Validation is in run(), not validate(), so any string parses
        let cmd = try BrowserCommand.Scroll.parse(["sideways"])
        XCTAssertEqual(cmd.direction, "sideways")
    }

    func testScrollSessionDirDefaultsToNil() throws {
        let cmd = try BrowserCommand.Scroll.parse(["up"])
        XCTAssertNil(cmd.sessionDir)
    }

    // MARK: - BrowserCommand.Tabs Parse Tests

    func testTabsParsesWithNoArgs() {
        XCTAssertNoThrow(try BrowserCommand.Tabs.parse([]))
    }

    func testTabsSessionDirDefaultsToNil() throws {
        let cmd = try BrowserCommand.Tabs.parse([])
        XCTAssertNil(cmd.sessionDir)
    }

    // MARK: - BrowserCommand.Close Parse Tests

    func testCloseParsesWithNoArgs() {
        XCTAssertNoThrow(try BrowserCommand.Close.parse([]))
    }

    func testCloseSessionDirDefaultsToNil() throws {
        let cmd = try BrowserCommand.Close.parse([])
        XCTAssertNil(cmd.sessionDir)
    }

    func testCloseParsesSessionDir() throws {
        let cmd = try BrowserCommand.Close.parse(["--session-dir", "/tmp/session"])
        XCTAssertEqual(cmd.sessionDir, "/tmp/session")
    }

    // MARK: - BrowserCommand.Fetch Parse Tests

    func testFetchParsesWithURL() {
        XCTAssertNoThrow(try BrowserCommand.Fetch.parse(["https://example.com"]))
    }

    func testFetchFailsWithoutURL() {
        XCTAssertThrowsError(try BrowserCommand.Fetch.parse([]))
    }

    func testFetchParsesURL() throws {
        let cmd = try BrowserCommand.Fetch.parse(["https://example.com/api"])
        XCTAssertEqual(cmd.url, "https://example.com/api")
    }

    // MARK: - BrowserBridgeError errorDescription

    func testNodeNotInstalledError() {
        let error = BrowserBridgeError.nodeNotInstalled
        XCTAssertEqual(error.errorDescription, "Node.js is not installed. Install via Homebrew: brew install node")
    }

    func testPlaywrightNotInstalledError() {
        let error = BrowserBridgeError.playwrightNotInstalled
        XCTAssertEqual(error.errorDescription, "Playwright is not installed. Install via npm: npm install -g playwright")
    }

    func testSessionNotActiveError() {
        let error = BrowserBridgeError.sessionNotActive
        XCTAssertEqual(error.errorDescription, "No active browser session. Use 'pippin browser open <url>' to start one.")
    }

    func testNavigationFailedError() {
        let error = BrowserBridgeError.navigationFailed("msg")
        XCTAssertEqual(error.errorDescription, "Browser navigation failed: msg")
    }

    func testElementNotFoundError() {
        let error = BrowserBridgeError.elementNotFound("@ref1")
        XCTAssertEqual(error.errorDescription, "Element not found: @ref1")
    }

    func testScriptFailedError() {
        let error = BrowserBridgeError.scriptFailed("err")
        XCTAssertEqual(error.errorDescription, "Browser script failed: err")
    }

    func testDecodingFailedError() {
        let error = BrowserBridgeError.decodingFailed("bad json")
        XCTAssertEqual(error.errorDescription, "Failed to decode browser response: bad json")
    }

    func testTimeoutError() {
        let error = BrowserBridgeError.timeout
        XCTAssertEqual(error.errorDescription, "Browser operation timed out")
    }

    func testFetchFailedError() {
        let error = BrowserBridgeError.fetchFailed("net")
        XCTAssertEqual(error.errorDescription, "HTTP fetch failed: net")
    }
}
