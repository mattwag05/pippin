@testable import PippinLib
import XCTest

final class TextFormatterTests: XCTestCase {
    // MARK: - Truncation

    func testTruncationShortString() {
        XCTAssertEqual(TextFormatter.truncate("hello", to: 10), "hello")
    }

    func testTruncationExactLength() {
        XCTAssertEqual(TextFormatter.truncate("hello", to: 5), "hello")
    }

    func testTruncationLongString() {
        let result = TextFormatter.truncate("hello world", to: 8)
        XCTAssertEqual(result.count, 8)
        XCTAssertTrue(result.hasSuffix("\u{2026}"), "Should end with ellipsis")
        XCTAssertEqual(result, "hello w\u{2026}")
    }

    func testTruncationEdgeCaseEmpty() {
        XCTAssertEqual(TextFormatter.truncate("", to: 5), "")
    }

    func testTruncationEdgeCaseLimitOne() {
        // maxLength=1 triggers the guard (maxLength > 1 is false), so returns as-is
        XCTAssertEqual(TextFormatter.truncate("hello", to: 1), "hello")
    }

    // MARK: - Duration formatting

    func testDurationSecondsOnly() {
        XCTAssertEqual(TextFormatter.duration(45), "45s")
    }

    func testDurationMinutesAndSeconds() {
        XCTAssertEqual(TextFormatter.duration(135), "2m 15s")
    }

    func testDurationExactMinutes() {
        XCTAssertEqual(TextFormatter.duration(120), "2m")
    }

    func testDurationHoursAndMinutes() {
        XCTAssertEqual(TextFormatter.duration(3900), "1h 5m")
    }

    func testDurationExactHours() {
        XCTAssertEqual(TextFormatter.duration(3600), "1h")
    }

    func testDurationZero() {
        XCTAssertEqual(TextFormatter.duration(0), "0s")
    }
}
