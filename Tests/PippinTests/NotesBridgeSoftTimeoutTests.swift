@testable import PippinLib
import XCTest

/// Tests for the Notes JXA scripts' soft-timeout pattern (parallel to
/// `JXAScriptBuilderTests` for mail). The scripts must inject `_start`,
/// `softTimeoutMs`, and an early-break check so a slow vault doesn't hang
/// past the MCP `runChild` 60s hard cap.
final class NotesBridgeSoftTimeoutTests: XCTestCase {
    // MARK: - buildSearchScript

    func testSearchScriptDefaultSoftTimeoutIs22000() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertTrue(script.contains("var softTimeoutMs = 22000;"), "Default soft timeout should be 22000ms.")
    }

    func testSearchScriptCustomSoftTimeoutInterpolated() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10, softTimeoutMs: 5000)
        XCTAssertTrue(script.contains("var softTimeoutMs = 5000;"))
    }

    func testSearchScriptSoftTimeoutClampedAt1sFloor() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10, softTimeoutMs: 0)
        XCTAssertTrue(script.contains("var softTimeoutMs = 1000;"))
    }

    func testSearchScriptSoftTimeoutClampedAt5minCeiling() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10, softTimeoutMs: 999_999_999)
        XCTAssertTrue(script.contains("var softTimeoutMs = 300000;"))
    }

    func testSearchScriptInjectsStartTimestamp() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertTrue(script.contains("var _start = Date.now();"))
    }

    func testSearchScriptHasEarlyBreakCheck() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertTrue(
            script.contains("Date.now() - _start > softTimeoutMs"),
            "Search loop must check elapsed time and break early."
        )
        XCTAssertTrue(script.contains("_meta.timedOut = true"))
    }

    func testSearchScriptInitializesMetaTimedOutFalse() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertTrue(script.contains("_meta = { timedOut: false }"))
    }

    func testSearchScriptWrapsResultsInResponseEnvelope() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertTrue(script.contains("JSON.stringify({results: results, meta: _meta})"))
    }

    // MARK: - buildListScript

    func testListScriptDefaultSoftTimeoutIs22000() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertTrue(script.contains("var softTimeoutMs = 22000;"))
    }

    func testListScriptInjectsStartTimestamp() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertTrue(script.contains("var _start = Date.now();"))
    }

    func testListScriptHasEarlyBreakCheck() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertTrue(script.contains("Date.now() - _start > softTimeoutMs"))
        XCTAssertTrue(script.contains("_meta.timedOut = true"))
    }

    func testListScriptWrapsResultsInResponseEnvelope() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertTrue(script.contains("JSON.stringify({results: results, meta: _meta})"))
    }

    // MARK: - buildListFoldersScript

    func testFoldersScriptDefaultSoftTimeoutIs22000() {
        let script = NotesBridge.buildListFoldersScript()
        XCTAssertTrue(script.contains("var softTimeoutMs = 22000;"))
    }

    func testFoldersScriptInjectsStartTimestamp() {
        let script = NotesBridge.buildListFoldersScript()
        XCTAssertTrue(script.contains("var _start = Date.now();"))
    }

    func testFoldersScriptHasEarlyBreakCheck() {
        let script = NotesBridge.buildListFoldersScript()
        XCTAssertTrue(script.contains("Date.now() - _start > softTimeoutMs"))
        XCTAssertTrue(script.contains("_meta.timedOut = true"))
    }

    func testFoldersScriptWrapsResultsInResponseEnvelope() {
        let script = NotesBridge.buildListFoldersScript()
        XCTAssertTrue(script.contains("JSON.stringify({results: results, meta: _meta})"))
    }

    // Soft-timeout clamp bounds are now tested in `SoftTimeoutTests`
    // (shared helper). Script-level interpolation stays here because it's
    // specific to the Notes JXA builders above.
}
