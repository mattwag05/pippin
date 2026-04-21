@testable import PippinLib
import XCTest

final class CursorTests: XCTestCase {
    // MARK: - Encode / decode round-trip

    func testCursorRoundTrip() throws {
        let original = Cursor(offset: 42, filterHash: "abcd1234")
        let token = try Pagination.encode(original)
        XCTAssertFalse(token.isEmpty)
        let decoded = try Pagination.decode(token)
        XCTAssertEqual(decoded, original)
    }

    func testCursorTokenIsBase64URLSafe() throws {
        let token = try Pagination.encode(Cursor(offset: 100, filterHash: "deadbeef"))
        // base64url uses [A-Za-z0-9_-]; no '+', '/', '='.
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="))
    }

    func testCursorDecodeRejectsGarbage() {
        XCTAssertThrowsError(try Pagination.decode("not-a-real-token!!"))
        XCTAssertThrowsError(try Pagination.decode(""))
    }

    func testCursorDecodeRejectsValidBase64ButBadJSON() {
        // base64 of "hello" — decodes but isn't a valid Cursor JSON object.
        XCTAssertThrowsError(try Pagination.decode("aGVsbG8"))
    }

    // MARK: - filterHash

    func testFilterHashStableAcrossKeyOrder() {
        let h1 = Pagination.filterHash(["a": "1", "b": "2", "c": "3"])
        let h2 = Pagination.filterHash(["c": "3", "a": "1", "b": "2"])
        XCTAssertEqual(h1, h2)
    }

    func testFilterHashChangesOnValueChange() {
        let h1 = Pagination.filterHash(["a": "1"])
        let h2 = Pagination.filterHash(["a": "2"])
        XCTAssertNotEqual(h1, h2)
    }

    func testFilterHashIgnoresNilAndEmpty() {
        let h1 = Pagination.filterHash(["a": "1", "b": nil, "c": ""])
        let h2 = Pagination.filterHash(["a": "1"])
        XCTAssertEqual(h1, h2)
    }

    func testFilterHashCaseInsensitive() {
        let h1 = Pagination.filterHash(["Account": "INBOX"])
        let h2 = Pagination.filterHash(["account": "inbox"])
        XCTAssertEqual(h1, h2)
    }

    func testFilterHashLength() {
        let h = Pagination.filterHash(["a": "1"])
        XCTAssertEqual(h.count, 16)
    }

    // MARK: - resolve / mismatch detection

    func testResolveDefaultsWhenNoFlags() throws {
        let opts = try PaginationOptions.parse([])
        XCTAssertFalse(opts.isActive)
        let (offset, size) = try Pagination.resolve(opts, defaultPageSize: 25, filterHash: "h")
        XCTAssertEqual(offset, 0)
        XCTAssertEqual(size, 25)
    }

    func testResolveRoundTripCursor() throws {
        let hash = "stableHash"
        let token = try Pagination.encode(Cursor(offset: 10, filterHash: hash))
        let opts = try PaginationOptions.parse(["--cursor", token, "--page-size", "5"])
        let (offset, size) = try Pagination.resolve(opts, defaultPageSize: 50, filterHash: hash)
        XCTAssertEqual(offset, 10)
        XCTAssertEqual(size, 5)
    }

    func testResolveRejectsCursorMismatch() throws {
        let token = try Pagination.encode(Cursor(offset: 10, filterHash: "oldHash"))
        let opts = try PaginationOptions.parse(["--cursor", token])
        XCTAssertThrowsError(try Pagination.resolve(opts, defaultPageSize: 20, filterHash: "newHash")) { error in
            guard case CursorError.cursorMismatch = error else {
                return XCTFail("expected cursorMismatch, got \(error)")
            }
        }
    }

    func testResolveRejectsZeroPageSize() throws {
        let opts = try PaginationOptions.parse(["--page-size", "0"])
        XCTAssertThrowsError(try Pagination.resolve(opts, defaultPageSize: 20, filterHash: "h")) { error in
            guard case CursorError.invalidPageSize = error else {
                return XCTFail("expected invalidPageSize, got \(error)")
            }
        }
    }

    func testResolveRejectsNegativePageSize() throws {
        // ArgumentParser treats bare `-1` as a flag; use --opt=value form to pass a negative.
        let opts = try PaginationOptions.parse(["--page-size=-1"])
        XCTAssertThrowsError(try Pagination.resolve(opts, defaultPageSize: 20, filterHash: "h"))
    }

    // MARK: - paginate (in-memory slicing)

    func testPaginateFirstPage() throws {
        let all = Array(1 ... 10)
        let page = try Pagination.paginate(all: all, offset: 0, pageSize: 3, filterHash: "h")
        XCTAssertEqual(page.items, [1, 2, 3])
        XCTAssertNotNil(page.nextCursor)
        let next = try Pagination.decode(XCTUnwrap(page.nextCursor))
        XCTAssertEqual(next.offset, 3)
        XCTAssertEqual(next.filterHash, "h")
    }

    func testPaginateMiddlePage() throws {
        let all = Array(1 ... 10)
        let page = try Pagination.paginate(all: all, offset: 3, pageSize: 4, filterHash: "h")
        XCTAssertEqual(page.items, [4, 5, 6, 7])
        XCTAssertNotNil(page.nextCursor)
    }

    func testPaginateLastPageExactBoundary() throws {
        let all = Array(1 ... 6)
        let page = try Pagination.paginate(all: all, offset: 3, pageSize: 3, filterHash: "h")
        XCTAssertEqual(page.items, [4, 5, 6])
        XCTAssertNil(page.nextCursor, "exact boundary should not emit a cursor")
    }

    func testPaginatePartialLastPage() throws {
        let all = Array(1 ... 5)
        let page = try Pagination.paginate(all: all, offset: 3, pageSize: 4, filterHash: "h")
        XCTAssertEqual(page.items, [4, 5])
        XCTAssertNil(page.nextCursor)
    }

    func testPaginateOffsetBeyondEnd() throws {
        let all = Array(1 ... 5)
        let page = try Pagination.paginate(all: all, offset: 100, pageSize: 5, filterHash: "h")
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    func testPaginateEmptyArray() throws {
        let page = try Pagination.paginate(all: [Int](), offset: 0, pageSize: 5, filterHash: "h")
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    // MARK: - pageFromPushdown

    func testPushdownHasMore() throws {
        let fetched = [1, 2, 3, 4]
        let page = try Pagination.pageFromPushdown(
            fetched: fetched, offset: 0, pageSize: 3, filterHash: "h"
        )
        XCTAssertEqual(page.items, [1, 2, 3])
        XCTAssertNotNil(page.nextCursor)
        let next = try Pagination.decode(XCTUnwrap(page.nextCursor))
        XCTAssertEqual(next.offset, 3)
    }

    func testPushdownExhausted() throws {
        let fetched = [1, 2, 3]
        let page = try Pagination.pageFromPushdown(
            fetched: fetched, offset: 0, pageSize: 3, filterHash: "h"
        )
        XCTAssertEqual(page.items, [1, 2, 3])
        XCTAssertNil(page.nextCursor)
    }

    func testPushdownPartial() throws {
        let fetched = [1, 2]
        let page = try Pagination.pageFromPushdown(
            fetched: fetched, offset: 5, pageSize: 5, filterHash: "h"
        )
        XCTAssertEqual(page.items, [1, 2])
        XCTAssertNil(page.nextCursor)
    }

    // MARK: - Page<T> encoding

    func testPageEncodingWithCursor() throws {
        let page = Page(items: [1, 2, 3], nextCursor: "tok")
        let data = try JSONEncoder().encode(page)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["items"] as? [Int], [1, 2, 3])
        XCTAssertEqual(dict["next_cursor"] as? String, "tok")
    }

    func testPageEncodingWithoutCursorOmitsField() throws {
        let page = Page<Int>(items: [1, 2, 3], nextCursor: nil)
        let data = try JSONEncoder().encode(page)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["items"] as? [Int], [1, 2, 3])
        XCTAssertNil(dict["next_cursor"])
        XCTAssertFalse(dict.keys.contains("next_cursor"))
    }

    // MARK: - End-to-end roundtrip

    func testRoundTripFirstAndSecondPage() throws {
        let all = Array(1 ... 7)
        let hash = Pagination.filterHash(["q": "x"])

        // Page 1 — request via --page-size only (no cursor yet).
        let opts1 = try PaginationOptions.parse(["--page-size", "3"])
        let (off1, size1) = try Pagination.resolve(opts1, defaultPageSize: 50, filterHash: hash)
        let page1 = try Pagination.paginate(all: all, offset: off1, pageSize: size1, filterHash: hash)
        XCTAssertEqual(page1.items, [1, 2, 3])
        let nextToken = try XCTUnwrap(page1.nextCursor)

        // Page 2 — feed the cursor back.
        let opts2 = try PaginationOptions.parse(["--cursor", nextToken, "--page-size", "3"])
        let (off2, size2) = try Pagination.resolve(opts2, defaultPageSize: 50, filterHash: hash)
        let page2 = try Pagination.paginate(all: all, offset: off2, pageSize: size2, filterHash: hash)
        XCTAssertEqual(page2.items, [4, 5, 6])

        // Page 3 — partial.
        let lastToken = try XCTUnwrap(page2.nextCursor)
        let opts3 = try PaginationOptions.parse(["--cursor", lastToken, "--page-size", "3"])
        let (off3, size3) = try Pagination.resolve(opts3, defaultPageSize: 50, filterHash: hash)
        let page3 = try Pagination.paginate(all: all, offset: off3, pageSize: size3, filterHash: hash)
        XCTAssertEqual(page3.items, [7])
        XCTAssertNil(page3.nextCursor)
    }
}
