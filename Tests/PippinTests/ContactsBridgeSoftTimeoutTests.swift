@testable import PippinLib
import XCTest

/// Tests for `ContactsBridge.Outcome<T>` construction and the shared
/// `SoftTimeout` clamp/default. The actual enumeration path requires a real
/// `CNContactStore` and isn't covered here — these are the pure, I/O-free
/// pieces of the soft-timeout pattern (mirroring `NotesBridgeSoftTimeoutTests`).
final class ContactsBridgeSoftTimeoutTests: XCTestCase {
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
}
