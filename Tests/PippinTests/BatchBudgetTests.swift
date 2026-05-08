@testable import PippinLib
import XCTest

final class BatchBudgetTests: XCTestCase {
    func testZeroSoftTimeoutNeverExceeds() {
        let b = BatchBudget(softTimeoutMs: 0)
        XCTAssertFalse(b.exceeded)
    }

    func testNegativeSoftTimeoutNeverExceeds() {
        let b = BatchBudget(softTimeoutMs: -1)
        XCTAssertFalse(b.exceeded)
    }

    func testFreshBudgetIsNotExceeded() {
        let b = BatchBudget(softTimeoutMs: 50000)
        XCTAssertFalse(b.exceeded)
    }

    func testBudgetExceededAfterElapsed() {
        let b = BatchBudget(softTimeoutMs: 10) // 10ms — should fire after sleep
        Thread.sleep(forTimeInterval: 0.05) // 50ms
        XCTAssertTrue(b.exceeded)
    }

    func testForCurrentContextDefaultsToUnboundedInCLI() {
        // Unit tests don't run under PIPPIN_MCP=1.
        let b = BatchBudget.forCurrentContext()
        XCTAssertEqual(b.softTimeoutMs, 0)
    }
}
