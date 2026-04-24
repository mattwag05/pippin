@testable import PippinLib
import XCTest

/// Tests for the shared `SoftTimeout` helper used by bridges that enumerate
/// unbounded collections (Contacts client-side, Notes via JXA).
final class SoftTimeoutTests: XCTestCase {
    func testDefaultMsIs22Seconds() {
        XCTAssertEqual(SoftTimeout.defaultMs, 22000)
    }

    func testClampBelowMinimumRaisesToFloor() {
        XCTAssertEqual(SoftTimeout.clamp(0), 1000)
        XCTAssertEqual(SoftTimeout.clamp(-1), 1000)
        XCTAssertEqual(SoftTimeout.clamp(999), 1000)
    }

    func testClampAboveMaximumLowersToCeiling() {
        XCTAssertEqual(SoftTimeout.clamp(300_001), 300_000)
        XCTAssertEqual(SoftTimeout.clamp(1_000_000), 300_000)
    }

    func testClampInRangePassesThrough() {
        XCTAssertEqual(SoftTimeout.clamp(1000), 1000)
        XCTAssertEqual(SoftTimeout.clamp(22000), 22000)
        XCTAssertEqual(SoftTimeout.clamp(300_000), 300_000)
    }
}
