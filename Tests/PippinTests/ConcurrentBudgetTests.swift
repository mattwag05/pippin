@testable import PippinLib
import XCTest

/// Deterministic tests for the concurrent-with-deadline runner that backs
/// `pippin status` (pippin-0nk). The status gathers are uncancellable blocking
/// work, so the runner bounds the *wait*, not the work: it returns at the
/// deadline with whatever finished and leaves stragglers running.
final class ConcurrentBudgetTests: XCTestCase {
    func testSlotIsNilUntilSet() {
        let slot = ConcurrentSlot<Int>()
        XCTAssertNil(slot.get())
        slot.set(42)
        XCTAssertEqual(slot.get(), 42)
    }

    func testAllFastTasksCompleteWithinBudget() {
        let a = ConcurrentSlot<Int>()
        let b = ConcurrentSlot<Int>()
        let completed = runConcurrentlyWithBudget(budgetMs: 2000, [
            { a.set(1) },
            { b.set(2) },
        ])
        XCTAssertTrue(completed)
        XCTAssertEqual(a.get(), 1)
        XCTAssertEqual(b.get(), 2)
    }

    func testSlowTaskExceedsBudgetAndYieldsPartialResults() {
        let fast = ConcurrentSlot<Int>()
        let slow = ConcurrentSlot<Int>()
        let start = Date()
        let completed = runConcurrentlyWithBudget(budgetMs: 200, [
            { fast.set(1) },
            { Thread.sleep(forTimeInterval: 2.0); slow.set(2) },
        ])
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(completed, "budget should fire before the 2s task finishes")
        XCTAssertEqual(fast.get(), 1, "the fast section completes within budget")
        XCTAssertNil(slow.get(), "the slow section is abandoned at the deadline")
        XCTAssertLessThan(elapsed, 1.5, "runner returns at ~the deadline, not after the straggler")
    }

    func testZeroBudgetWaitsForEverything() {
        let slow = ConcurrentSlot<Int>()
        let completed = runConcurrentlyWithBudget(budgetMs: 0, [
            { Thread.sleep(forTimeInterval: 0.2); slow.set(9) },
        ])
        XCTAssertTrue(completed)
        XCTAssertEqual(slow.get(), 9)
    }

    func testTasksRunConcurrentlyNotSequentially() {
        // Three 300ms tasks run concurrently should finish well under their
        // 900ms serial sum — this is the core of the pippin-0nk fix.
        let slots = (0 ..< 3).map { _ in ConcurrentSlot<Int>() }
        let start = Date()
        let completed = runConcurrentlyWithBudget(budgetMs: 5000, slots.map { slot in
            { Thread.sleep(forTimeInterval: 0.3); slot.set(1) }
        })
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(completed)
        XCTAssertTrue(slots.allSatisfy { $0.get() == 1 })
        XCTAssertLessThan(elapsed, 0.7, "concurrent execution beats the 0.9s serial sum")
    }
}
