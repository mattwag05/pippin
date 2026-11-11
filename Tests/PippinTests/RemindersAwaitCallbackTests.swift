@testable import PippinLib
import XCTest

/// `RemindersBridge.awaitCallback` bounds a completion-handler fetch. A late
/// callback must never leak into a timed-out result (pippin-xr89 ARC-4).
final class RemindersAwaitCallbackTests: XCTestCase {
    func testReturnsCallbackValueWhenItFiresInTime() {
        let (value, timedOut) = RemindersBridge.awaitCallback(timeoutSeconds: 2, empty: [Int]()) { done in
            DispatchQueue.global().async { done([1, 2, 3]) }
        }
        XCTAssertFalse(timedOut)
        XCTAssertEqual(value, [1, 2, 3])
    }

    func testTimeoutReturnsEmptyEvenIfCallbackFiresLater() {
        let fired = expectation(description: "late callback fired")
        let (value, timedOut) = RemindersBridge.awaitCallback(timeoutSeconds: 1, empty: [Int]()) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                done([9])
                fired.fulfill()
            }
        }
        XCTAssertTrue(timedOut)
        XCTAssertEqual(value, [], "a timed-out fetch must not expose a value written after the deadline")
        wait(for: [fired], timeout: 3)
    }
}
