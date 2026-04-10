@testable import PippinLib
import XCTest

final class ConcurrencyUtilsTests: XCTestCase {
    func testRunConcurrentlyPreservesOrder() throws {
        let items = [1, 2, 3, 4, 5]
        let results = try runConcurrently(items) { $0 * 10 }
        XCTAssertEqual(results, [10, 20, 30, 40, 50])
    }

    func testRunConcurrentlyEmpty() throws {
        let results: [Int] = try runConcurrently([]) { $0 }
        XCTAssertEqual(results, [])
    }

    func testRunConcurrentlyWithMaxConcurrent() throws {
        let items = Array(0 ..< 20)
        let results = try runConcurrently(items, maxConcurrent: 2) { $0 * 2 }
        XCTAssertEqual(results, items.map { $0 * 2 })
    }

    func testRunConcurrentlyFailFastThrows() {
        struct TestError: Error {}
        let items = [1, 2, 3, 4, 5]
        XCTAssertThrowsError(try runConcurrently(items, failFast: true) { item -> Int in
            if item == 3 { throw TestError() }
            return item
        })
    }

    func testRunConcurrentlyNoFailFastDropsErrors() throws {
        struct TestError: Error {}
        let items = [1, 2, 3, 4, 5]
        let results = try runConcurrently(items, failFast: false) { item -> Int in
            if item == 3 { throw TestError() }
            return item * 10
        }
        // Item 3 should be dropped; others preserved in order
        XCTAssertEqual(results, [10, 20, 40, 50])
    }

    func testRunConcurrentlySingleItem() throws {
        let results = try runConcurrently(["hello"]) { $0.uppercased() }
        XCTAssertEqual(results, ["HELLO"])
    }

    func testRunConcurrentlyMaxConcurrentOne() throws {
        // Sequential execution with maxConcurrent: 1
        let items = [10, 20, 30]
        let results = try runConcurrently(items, maxConcurrent: 1) { $0 + 1 }
        XCTAssertEqual(results, [11, 21, 31])
    }
}
