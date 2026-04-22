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

    // MARK: - --format agent support (Screenshot, Click, Fill, Scroll, Close)

    func testScreenshotParsesFormatAgent() throws {
        let cmd = try BrowserCommand.Screenshot.parse(["--format", "agent"])
        XCTAssertTrue(cmd.output.isAgent)
    }

    func testScreenshotParsesFormatJSON() throws {
        let cmd = try BrowserCommand.Screenshot.parse(["--format", "json"])
        XCTAssertTrue(cmd.output.isJSON)
    }

    func testScreenshotDefaultFormatIsText() throws {
        let cmd = try BrowserCommand.Screenshot.parse([])
        XCTAssertFalse(cmd.output.isStructured)
    }

    func testClickParsesFormatAgent() throws {
        let cmd = try BrowserCommand.Click.parse(["@ref1", "--format", "agent"])
        XCTAssertTrue(cmd.output.isAgent)
    }

    func testClickParsesFormatJSON() throws {
        let cmd = try BrowserCommand.Click.parse(["@ref1", "--format", "json"])
        XCTAssertTrue(cmd.output.isJSON)
    }

    func testClickDefaultFormatIsText() throws {
        let cmd = try BrowserCommand.Click.parse(["@ref1"])
        XCTAssertFalse(cmd.output.isStructured)
    }

    func testFillParsesFormatAgent() throws {
        let cmd = try BrowserCommand.Fill.parse(["@ref2", "hello", "--format", "agent"])
        XCTAssertTrue(cmd.output.isAgent)
    }

    func testScrollParsesFormatAgent() throws {
        let cmd = try BrowserCommand.Scroll.parse(["down", "--format", "agent"])
        XCTAssertTrue(cmd.output.isAgent)
    }

    func testScrollDefaultFormatIsText() throws {
        let cmd = try BrowserCommand.Scroll.parse(["down"])
        XCTAssertFalse(cmd.output.isStructured)
    }

    func testCloseParsesFormatAgent() throws {
        let cmd = try BrowserCommand.Close.parse(["--format", "agent"])
        XCTAssertTrue(cmd.output.isAgent)
    }

    func testCloseDefaultFormatIsText() throws {
        let cmd = try BrowserCommand.Close.parse([])
        XCTAssertFalse(cmd.output.isStructured)
    }

    // MARK: - BrowserActionResult encoding

    func testBrowserActionResultEncoding() throws {
        let result = BrowserActionResult(success: true, action: "click", details: ["ref": "@ref3"])
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["success"] as? Bool, true)
        XCTAssertEqual(dict["action"] as? String, "click")
        let details = try XCTUnwrap(dict["details"] as? [String: String])
        XCTAssertEqual(details["ref"], "@ref3")
    }

    func testBrowserActionResultEmptyDetails() {
        let result = BrowserActionResult(success: true, action: "close")
        XCTAssertTrue(result.details.isEmpty)
    }

    // MARK: - BrowserRetry — JSON path walker

    func testWalkJSONPathSimpleKey() {
        let json: Any = ["title": "Hello"]
        XCTAssertEqual(BrowserRetry.walkJSONPath(json, path: "title") as? String, "Hello")
    }

    func testWalkJSONPathNested() {
        let json: Any = ["data": ["title": "X"]]
        XCTAssertEqual(BrowserRetry.walkJSONPath(json, path: "data.title") as? String, "X")
    }

    func testWalkJSONPathArrayIndex() {
        let json: Any = ["items": ["a", "b", "c"]]
        XCTAssertEqual(BrowserRetry.walkJSONPath(json, path: "items.1") as? String, "b")
    }

    func testWalkJSONPathMissingKey() {
        let json: Any = ["a": 1]
        XCTAssertNil(BrowserRetry.walkJSONPath(json, path: "b"))
    }

    func testWalkJSONPathOutOfBoundsIndex() {
        let json: Any = ["items": ["a"]]
        XCTAssertNil(BrowserRetry.walkJSONPath(json, path: "items.5"))
    }

    // MARK: - BrowserRetry — isNonEmpty

    func testIsNonEmptyString() {
        XCTAssertTrue(BrowserRetry.isNonEmpty("x"))
        XCTAssertFalse(BrowserRetry.isNonEmpty(""))
    }

    func testIsNonEmptyArray() {
        XCTAssertTrue(BrowserRetry.isNonEmpty([1, 2]))
        XCTAssertFalse(BrowserRetry.isNonEmpty([Any]()))
    }

    func testIsNonEmptyDict() {
        XCTAssertTrue(BrowserRetry.isNonEmpty(["a": 1]))
        XCTAssertFalse(BrowserRetry.isNonEmpty([String: Any]()))
    }

    func testIsNonEmptyNull() {
        XCTAssertFalse(BrowserRetry.isNonEmpty(NSNull()))
    }

    func testIsNonEmptyZero() {
        // Numbers/bools count as present — only null/empty-string/empty-collection fail.
        XCTAssertTrue(BrowserRetry.isNonEmpty(0))
        XCTAssertTrue(BrowserRetry.isNonEmpty(false))
    }

    // MARK: - BrowserRetry — expectFieldSatisfied

    func testExpectFieldNilReturnsTrue() throws {
        let v = PageInfo(url: "x", title: "y")
        XCTAssertTrue(try BrowserRetry.expectFieldSatisfied(v, path: nil))
    }

    func testExpectFieldEmptyTitleFalse() throws {
        let v = PageInfo(url: "x", title: "")
        XCTAssertFalse(try BrowserRetry.expectFieldSatisfied(v, path: "title"))
    }

    func testExpectFieldPresentTitleTrue() throws {
        let v = PageInfo(url: "x", title: "Hello")
        XCTAssertTrue(try BrowserRetry.expectFieldSatisfied(v, path: "title"))
    }

    func testExpectFieldNullStatusFalse() throws {
        let v = PageInfo(url: "x", title: "t", status: nil)
        XCTAssertFalse(try BrowserRetry.expectFieldSatisfied(v, path: "status"))
    }

    // MARK: - BrowserRetry — retry mechanics

    func testRetryStopsOnFirstSuccessNoExpect() async throws {
        var calls = 0
        let r = try await BrowserRetry.run(retry: 3, delayMs: 0, expectField: nil) {
            calls += 1
            return PageInfo(url: "x", title: "y")
        }
        XCTAssertEqual(r.attempts, 1)
        XCTAssertEqual(calls, 1)
    }

    func testRetryRunsAllAttemptsWhenExpectFails() async throws {
        var calls = 0
        let r = try await BrowserRetry.run(retry: 2, delayMs: 0, expectField: "title") {
            calls += 1
            return PageInfo(url: "x", title: "")
        }
        XCTAssertEqual(r.attempts, 3)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(r.result.title, "")
    }

    func testRetryStopsOnExpectSatisfied() async throws {
        var calls = 0
        let r = try await BrowserRetry.run(retry: 5, delayMs: 0, expectField: "title") { () -> PageInfo in
            calls += 1
            return PageInfo(url: "x", title: calls >= 3 ? "loaded" : "")
        }
        XCTAssertEqual(r.attempts, 3)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(r.result.title, "loaded")
    }

    func testRetryPropagatesFirstErrorImmediately() async {
        // Errors are non-retryable: the first throw propagates, no further attempts.
        var calls = 0
        do {
            _ = try await BrowserRetry.run(retry: 2, delayMs: 0, expectField: nil) { () -> PageInfo in
                calls += 1
                throw BrowserBridgeError.scriptFailed("boom")
            }
            XCTFail("expected throw")
        } catch BrowserBridgeError.scriptFailed {
            // expected
        } catch {
            XCTFail("expected scriptFailed, got \(error)")
        }
        XCTAssertEqual(calls, 1, "errors should not trigger retries")
    }

    func testRetryReturnsPartialOnExhaustedExpectFail() async throws {
        // Operation always returns (no throw), expect-field never satisfied;
        // helper should return last seen value, not throw.
        let r = try await BrowserRetry.run(retry: 1, delayMs: 0, expectField: "title") {
            PageInfo(url: "x", title: "")
        }
        XCTAssertEqual(r.attempts, 2)
        XCTAssertEqual(r.result.url, "x")
    }

    // MARK: - WithAttempts encoding

    func testWithAttemptsEncoding() throws {
        let v = PageInfo(url: "https://x", title: "T")
        let wrapped = WithAttempts(payload: v, attempts: 2)
        let data = try JSONEncoder().encode(wrapped)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["url"] as? String, "https://x")
        XCTAssertEqual(dict["title"] as? String, "T")
        XCTAssertEqual(dict["_attempts"] as? Int, 2)
    }

    // MARK: - Open / Snapshot retry-flag parsing

    func testOpenParsesRetryFlags() throws {
        let cmd = try BrowserCommand.Open.parse([
            "https://x", "--retry", "3", "--expect-field", "title", "--retry-delay-ms", "100",
        ])
        XCTAssertEqual(cmd.retry, 3)
        XCTAssertEqual(cmd.expectField, "title")
        XCTAssertEqual(cmd.retryDelayMs, 100)
    }

    func testOpenRetryDefaults() throws {
        let cmd = try BrowserCommand.Open.parse(["https://x"])
        XCTAssertEqual(cmd.retry, 0)
        XCTAssertNil(cmd.expectField)
        XCTAssertEqual(cmd.retryDelayMs, 500)
    }

    func testSnapshotParsesRetryFlags() throws {
        let cmd = try BrowserCommand.Snapshot.parse([
            "--retry", "5", "--expect-field", "title", "--retry-delay-ms", "50",
        ])
        XCTAssertEqual(cmd.retry, 5)
        XCTAssertEqual(cmd.expectField, "title")
        XCTAssertEqual(cmd.retryDelayMs, 50)
    }

    func testSnapshotRetryDefaults() throws {
        let cmd = try BrowserCommand.Snapshot.parse([])
        XCTAssertEqual(cmd.retry, 0)
        XCTAssertNil(cmd.expectField)
        XCTAssertEqual(cmd.retryDelayMs, 500)
    }

    // MARK: - Fetch retry-flag parsing (pippin-tss)

    func testFetchParsesRetryFlags() throws {
        let cmd = try BrowserCommand.Fetch.parse([
            "https://x", "--retry", "4", "--expect-field", "content", "--retry-delay-ms", "250",
        ])
        XCTAssertEqual(cmd.retry, 4)
        XCTAssertEqual(cmd.expectField, "content")
        XCTAssertEqual(cmd.retryDelayMs, 250)
    }

    func testFetchRetryDefaults() throws {
        let cmd = try BrowserCommand.Fetch.parse(["https://x"])
        XCTAssertEqual(cmd.retry, 0)
        XCTAssertNil(cmd.expectField)
        XCTAssertEqual(cmd.retryDelayMs, 500)
    }

    func testFetchAcceptsFormatAgent() throws {
        XCTAssertNoThrow(try BrowserCommand.Fetch.parse(["https://x", "--format", "agent"]))
    }

    // MARK: - BrowserRetry — FetchResult payload shape

    func testExpectFieldContentEmptyFalse() throws {
        let v = FetchResult(url: "https://x", content: "")
        XCTAssertFalse(try BrowserRetry.expectFieldSatisfied(v, path: "content"))
    }

    func testExpectFieldContentPresentTrue() throws {
        let v = FetchResult(url: "https://x", content: "<html>hi</html>")
        XCTAssertTrue(try BrowserRetry.expectFieldSatisfied(v, path: "content"))
    }

    func testRetryReturnsFetchResultOnFirstHit() async throws {
        var calls = 0
        let r = try await BrowserRetry.run(retry: 2, delayMs: 0, expectField: "content") {
            calls += 1
            return FetchResult(url: "https://x", content: calls >= 2 ? "<body/>" : "")
        }
        XCTAssertEqual(r.attempts, 2)
        XCTAssertEqual(r.result.content, "<body/>")
    }

    func testFetchResultWithAttemptsEncoding() throws {
        let v = FetchResult(url: "https://x", content: "hi")
        let wrapped = WithAttempts(payload: v, attempts: 3)
        let data = try JSONEncoder().encode(wrapped)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["url"] as? String, "https://x")
        XCTAssertEqual(dict["content"] as? String, "hi")
        XCTAssertEqual(dict["_attempts"] as? Int, 3)
    }
}
