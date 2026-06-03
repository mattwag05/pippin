@testable import PippinLib
import XCTest

/// Tests for `RemindersBridge.Outcome<T>` construction and the timed-out hint
/// surfaced when the EventKit fetch hits its 15s wall-clock cap. The real fetch
/// path needs a live `EKEventStore`, so (mirroring `ContactsBridgeSoftTimeoutTests`)
/// these cover the pure, I/O-free pieces of the soft-timeout pattern.
final class RemindersBridgeSoftTimeoutTests: XCTestCase {
    func testOutcomeConstructionPreservesFields() {
        let outcome = RemindersBridge.Outcome<[Int]>(results: [1, 2, 3], timedOut: false)
        XCTAssertEqual(outcome.results, [1, 2, 3])
        XCTAssertFalse(outcome.timedOut)
    }

    func testOutcomeTimedOutFlag() {
        let outcome = RemindersBridge.Outcome<[Int]>(results: [], timedOut: true)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertTrue(outcome.results.isEmpty)
    }

    /// The list and search subcommands must agree on a single advisory string so
    /// the partial-results warning reads identically across both paths.
    func testListAndSearchShareTimedOutHint() {
        XCTAssertEqual(RemindersCommand.List.timedOutHint, RemindersCommand.Search.timedOutHint)
        XCTAssertFalse(RemindersCommand.List.timedOutHint.isEmpty)
        XCTAssertTrue(RemindersCommand.List.timedOutHint.contains("--list"))
    }
}
