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

    /// Regression for pippin-4as: the sort must run on plain JS numbers, never
    /// a comparator that fires an Apple Event per comparison.
    func testSearchScriptSortsInMemoryNotWithAnAppleEventComparator() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertFalse(script.contains("b.modificationDate() - a.modificationDate()"))
        XCTAssertTrue(script.contains("rows.sort(function(a, b) { return b.mod - a.mod; })"))
    }

    /// Regression for pippin-mo7: every column comes from one bulk read on the
    /// plural specifier, never from a per-note loop. What the scripts actually
    /// read is pinned by execution in `NotesScriptBehaviorTests`.
    func testSearchScriptBulkFetchesColumnsNotPerNote() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertFalse(script.contains("notes[j].modificationDate()"))
        XCTAssertFalse(script.contains("note.name()"))
        XCTAssertTrue(script.contains("_bulkRead(") && script.contains("'modificationDate'"))
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

    /// Regression for pippin-4as: see the search counterpart.
    func testListScriptSortsInMemoryNotWithAnAppleEventComparator() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertFalse(script.contains("b.modificationDate() - a.modificationDate()"))
        XCTAssertTrue(script.contains("if (a.mod !== b.mod) { return b.mod - a.mod; }"))
    }

    /// Regression for pippin-mo7: see the search counterpart.
    func testListScriptBulkFetchesColumnsNotPerNote() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertFalse(script.contains("notes[j].modificationDate()"))
        XCTAssertFalse(script.contains("note.name()"))
        XCTAssertTrue(script.contains("_bulkRead(") && script.contains("'modificationDate'"))
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

    /// The folders script has no per-folder Apple Events left to bound: it is
    /// three bulk reads (see `NotesScriptBehaviorTests`).
    func testFoldersScriptHasNoPerFolderLoopToBound() {
        let script = NotesBridge.buildListFoldersScript()
        XCTAssertTrue(script.contains("_folderIndex(true)"))
        XCTAssertFalse(script.contains("f.notes().length"))
    }

    func testFoldersScriptWrapsResultsInResponseEnvelope() {
        let script = NotesBridge.buildListFoldersScript()
        XCTAssertTrue(script.contains("JSON.stringify({results: results, meta: _meta})"))
    }

    // MARK: - buildCountScript (pippin-9s6)

    func testCountScriptDoesNotIterateBodies() {
        // The fix is precisely "don't fetch bodies/plaintext per note." If the
        // count script grows a body fetch, Notes status will hang again.
        let script = NotesBridge.buildCountScript(folder: nil)
        XCTAssertFalse(script.contains(".body()"), "Count script must not call .body()")
        XCTAssertFalse(script.contains(".plaintext()"), "Count script must not call .plaintext()")
    }

    func testCountScriptUsesSingleAppleEvent() {
        let script = NotesBridge.buildCountScript(folder: nil)
        XCTAssertTrue(script.contains("app.notes.length"), "Whole-vault count is one count event on the specifier.")
        XCTAssertFalse(script.contains("app.notes().length"), "Must not materialize every note to count.")
    }

    func testCountScriptHonorsFolderFilter() {
        let script = NotesBridge.buildCountScript(folder: "Work")
        XCTAssertTrue(script.contains("'Work'"))
        XCTAssertTrue(script.contains("folders[0].notes.length"))
    }

    func testCountScriptEscapesFolderName() {
        // jsEscape must apply — single quotes in a folder name should be escaped.
        let script = NotesBridge.buildCountScript(folder: "O'Reilly")
        XCTAssertFalse(
            script.contains("'O'Reilly'"),
            "Folder name with apostrophe must be escaped, not interpolated raw"
        )
        XCTAssertTrue(script.contains("O\\'Reilly") || script.contains("\\'Reilly"))
    }

    // MARK: - Pre-loop fetch+sort guard (pippin-4as)

    func testSearchScriptBoundsItsOnlyPerNoteLoop() {
        // The bulk reads cannot starve the budget; the per-note plaintext
        // fallback can, so it carries the soft-cap check.
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertTrue(script.contains("Date.now() - _start > softTimeoutMs"))
        XCTAssertTrue(script.contains("_meta.timedOut = true"))
    }

    func testListScriptBoundsItsPerRowReads() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertTrue(script.contains("Date.now() - _start > softTimeoutMs"))
        XCTAssertTrue(script.contains("_meta.timedOut = true"))
    }

    // Soft-timeout clamp bounds are now tested in `SoftTimeoutTests`
    // (shared helper). Script-level interpolation stays here because it's
    // specific to the Notes JXA builders above.
}
