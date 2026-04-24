@testable import PippinLib
import XCTest

/// Tests for `ContactsBridge.Outcome<T>` construction and `softTimeoutMs`
/// clamp. The actual enumeration path requires a real `CNContactStore` and
/// isn't covered here — these are the pure, I/O-free pieces of the
/// soft-timeout pattern (mirroring `NotesBridgeSoftTimeoutTests`).
final class ContactsBridgeSoftTimeoutTests: XCTestCase {
    func testDefaultSoftTimeoutMatchesNotesMail() {
        XCTAssertEqual(ContactsBridge.defaultSoftTimeoutMs, 22000)
    }

    func testOutcomeConstructionPreservesFields() {
        let outcome = ContactsBridge.Outcome<[Int]>(results: [1, 2, 3], timedOut: false)
        XCTAssertEqual(outcome.results, [1, 2, 3])
        XCTAssertFalse(outcome.timedOut)
    }

    func testOutcomeTimedOutFlag() {
        let outcome = ContactsBridge.Outcome<[Int]>(results: [], timedOut: true)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertTrue(outcome.results.isEmpty)
    }

    func testClampSoftTimeoutBelowMinimumRaisesToFloor() {
        XCTAssertEqual(ContactsBridge.clampSoftTimeoutMs(0), 1000)
        XCTAssertEqual(ContactsBridge.clampSoftTimeoutMs(-1), 1000)
        XCTAssertEqual(ContactsBridge.clampSoftTimeoutMs(999), 1000)
    }

    func testClampSoftTimeoutAboveMaximumLowersToCeiling() {
        XCTAssertEqual(ContactsBridge.clampSoftTimeoutMs(300_001), 300_000)
        XCTAssertEqual(ContactsBridge.clampSoftTimeoutMs(1_000_000), 300_000)
    }

    func testClampSoftTimeoutInRangePassesThrough() {
        XCTAssertEqual(ContactsBridge.clampSoftTimeoutMs(1000), 1000)
        XCTAssertEqual(ContactsBridge.clampSoftTimeoutMs(22000), 22000)
        XCTAssertEqual(ContactsBridge.clampSoftTimeoutMs(300_000), 300_000)
    }
}
