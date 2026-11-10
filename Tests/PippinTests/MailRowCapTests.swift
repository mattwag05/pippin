@testable import PippinLib
import XCTest

/// A request above the 500-row cap must say so, and a paginated one must keep
/// its `next_cursor` (RC-20).
final class MailRowCapTests: XCTestCase {
    private func rows(_ count: Int) -> [Int] {
        Array(0 ..< count)
    }

    func testPageSizeAboveTheCapStillGetsANextCursor() throws {
        for requested in [500, 501, 600, 100_000] {
            let (pageSize, _) = MailCommand.cappedPageSize(requested)
            // What the bridge hands back from a mailbox holding more than a page.
            let fetched = rows(MailBridge.clampScanLimit(pageSize + 1, pageSentinel: true))
            let page = try Pagination.pageFromPushdown(fetched: fetched, offset: 0, pageSize: pageSize, filterHash: "h")
            XCTAssertEqual(page.items.count, 500, "\(requested)")
            let cursor = try Pagination.decode(XCTUnwrap(page.nextCursor, "page size \(requested) lost its cursor"))
            XCTAssertEqual(cursor.offset, 500)
        }
    }

    func testLastPageHasNoCursor() throws {
        let (pageSize, _) = MailCommand.cappedPageSize(600)
        let page = try Pagination.pageFromPushdown(fetched: rows(120), offset: 500, pageSize: pageSize, filterHash: "h")
        XCTAssertNil(page.nextCursor)
    }

    func testReducedPageSizeIsAnnounced() {
        XCTAssertNil(MailCommand.cappedPageSize(500).note)
        XCTAssertEqual(MailCommand.cappedPageSize(200).size, 200)
        XCTAssertTrue(MailCommand.cappedPageSize(501).note?.contains("next_cursor") == true)
    }

    func testOnlyAPaginatedCallerGetsTheSentinelRow() {
        XCTAssertEqual(MailBridge.clampScanLimit(9999, pageSentinel: false), 500)
        XCTAssertEqual(MailBridge.clampScanLimit(9999, pageSentinel: true), 501)
        XCTAssertEqual(MailBridge.clampScanLimit(0, pageSentinel: false), 1)
        XCTAssertTrue(MailBridge.buildSearchScript(query: "q", account: nil, limit: 501, pageSentinel: true).contains("var limit = 501;"))
        XCTAssertTrue(MailBridge.buildSearchScript(query: "q", account: nil, limit: 501).contains("var limit = 500;"))
    }

    func testClampedLimitWarnsAndMarksTheAnswerPartial() {
        let note = MailBridge.rowCapNote(requested: 600, returned: 500)
        XCTAssertTrue(note?.contains("--cursor") == true)
        XCTAssertNil(MailBridge.rowCapNote(requested: 600, returned: 320), "fewer rows than the cap means nothing was cut")
        XCTAssertNil(MailBridge.rowCapNote(requested: 500, returned: 500), "the cap itself was not exceeded")

        let cut = MailCommand.incomplete(timedOut: false, timedOutHint: "t", notes: [note], advisories: ["fyi"])
        XCTAssertTrue(cut.partial)
        XCTAssertEqual(cut.warnings, [note, "fyi"].compactMap { $0 })

        let whole = MailCommand.incomplete(timedOut: false, timedOutHint: "t", notes: [nil], advisories: ["fyi"])
        XCTAssertFalse(whole.partial, "an advisory alone is not truncation")
        XCTAssertEqual(whole.warnings, ["fyi"])
        XCTAssertNil(MailCommand.incomplete(timedOut: false, timedOutHint: "t", notes: []).warnings)
        XCTAssertEqual(MailCommand.incomplete(timedOut: true, timedOutHint: "t", notes: []).warnings, ["t"])
    }
}
