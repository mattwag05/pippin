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

    /// Regression for pippin-4as: search must sort the materialized JS array,
    /// not a comparator that fires Apple Events per comparison. See the
    /// buildListScript counterpart for the full rationale.
    func testSearchScriptSortsMaterializedArrayNotAppleEventComparator() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertFalse(script.contains("b.modificationDate() - a.modificationDate()"))
        XCTAssertTrue(script.contains("pairs.sort(function(a, b) { return b.mod - a.mod; })"))
        XCTAssertTrue(script.contains("var note = pairs[i].note;"))
    }

    /// Regression for pippin-mo7: the modificationDate materialization must use a
    /// single bulk Apple Event off the collection specifier, NOT one Apple Event
    /// per note. The per-note form spent the entire soft-timeout building `pairs`
    /// on large vaults, so the sort loop broke with `pairs` empty and the call
    /// returned ZERO results (unusable default `notes search`).
    func testSearchScriptBulkFetchesModDatesNotPerNote() {
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        XCTAssertFalse(
            script.contains("notes[j].modificationDate()"),
            "Per-note modificationDate() in the sort loop is O(n) Apple Events — must be bulk-fetched"
        )
        XCTAssertTrue(
            script.contains("_notesRef.modificationDate()"),
            "modificationDate must be bulk-fetched off the specifier in one Apple Event"
        )
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

    /// Regression for pippin-4as: the sort must NOT call `.modificationDate()`
    /// inside the comparator. That naive form fires an Apple Event per
    /// comparison (O(n log n) round-trips) and can blow the ScriptRunner hard
    /// cap on large vaults before any partial result is returned. The builder
    /// must materialize modificationDate once per note, then sort a plain JS
    /// array (zero Apple Events during the sort).
    func testListScriptSortsMaterializedArrayNotAppleEventComparator() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertFalse(
            script.contains("b.modificationDate() - a.modificationDate()"),
            "Sort comparator must not fire an Apple Event per comparison"
        )
        XCTAssertTrue(
            script.contains("pairs.sort(function(a, b) { return b.mod - a.mod; })"),
            "Sort must operate on the materialized numeric `mod` field"
        )
        // The results loop must reuse the cached ISO string rather than re-fetching.
        XCTAssertTrue(script.contains("modificationDate: pairs[i].iso"))
    }

    /// Regression for pippin-mo7: the modificationDate materialization must use a
    /// single bulk Apple Event off the collection specifier, NOT one Apple Event
    /// per note. The per-note form (`notes[j].modificationDate()`) spent the
    /// entire soft-timeout building `pairs` on large vaults, so the sort loop
    /// broke with `pairs` empty and `notes list` returned ZERO results without
    /// `--folder`. Narrowing with `--folder` worked only because the collection
    /// was small enough to scan inside the cap.
    func testListScriptBulkFetchesModDatesNotPerNote() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        XCTAssertFalse(
            script.contains("notes[j].modificationDate()"),
            "Per-note modificationDate() in the sort loop is O(n) Apple Events — must be bulk-fetched"
        )
        XCTAssertTrue(
            script.contains("_notesRef.modificationDate()"),
            "modificationDate must be bulk-fetched off the specifier in one Apple Event"
        )
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
        XCTAssertTrue(
            script.contains("app.notes().length"),
            "Whole-vault count must call app.notes().length once."
        )
        XCTAssertTrue(script.contains("JSON.stringify({count: n})"))
    }

    func testCountScriptHonorsFolderFilter() {
        let script = NotesBridge.buildCountScript(folder: "Work")
        XCTAssertTrue(script.contains("'Work'"))
        XCTAssertTrue(script.contains("folders[0].notes().length"))
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

    func testSearchScriptHasPreSortBudgetCheck() {
        // Large vaults can spend the entire soft cap before the sort; the
        // modificationDate materialization loop must be time-checked and must
        // precede the (now pure-JS) sort, so a slow vault self-bounds and emits
        // timedOut=true rather than blowing the ScriptRunner hard cap.
        let script = NotesBridge.buildSearchScript(query: "x", folder: nil, limit: 10)
        let firstCheck = script.range(of: "Date.now() - _start > softTimeoutMs")
        XCTAssertNotNil(firstCheck)
        // The first time check must precede the materialized-array sort.
        let sortRange = script.range(of: "pairs.sort(function(a, b) { return b.mod - a.mod; })")
        XCTAssertNotNil(sortRange)
        if let first = firstCheck, let sort = sortRange {
            XCTAssertTrue(
                first.lowerBound < sort.lowerBound,
                "Time-checked materialization loop must appear before pairs.sort"
            )
        }
    }

    func testListScriptHasPreSortBudgetCheck() {
        let script = NotesBridge.buildListScript(folder: nil, limit: 10)
        let firstCheck = script.range(of: "Date.now() - _start > softTimeoutMs")
        XCTAssertNotNil(firstCheck)
        let sortRange = script.range(of: "pairs.sort(function(a, b) { return b.mod - a.mod; })")
        XCTAssertNotNil(sortRange)
        if let first = firstCheck, let sort = sortRange {
            XCTAssertTrue(
                first.lowerBound < sort.lowerBound,
                "Time-checked materialization loop must appear before pairs.sort"
            )
        }
    }

    // Soft-timeout clamp bounds are now tested in `SoftTimeoutTests`
    // (shared helper). Script-level interpolation stays here because it's
    // specific to the Notes JXA builders above.
}
