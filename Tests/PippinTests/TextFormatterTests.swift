@testable import PippinLib
import XCTest

final class TextFormatterTests: XCTestCase {
    // MARK: - Table formatting

    func testTableFormatting() {
        let result = TextFormatter.table(
            headers: ["NAME", "VALUE"],
            rows: [["alpha", "1"], ["beta", "2"]],
            columnWidths: [10, 10]
        )
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 4, "Header + separator + 2 rows")
        XCTAssertTrue(lines[0].hasPrefix("NAME"))
        // Separator line should be 80 chars of ─
        XCTAssertEqual(lines[1], String(repeating: "\u{2500}", count: 80))
        XCTAssertTrue(lines[2].hasPrefix("alpha"))
        XCTAssertTrue(lines[3].hasPrefix("beta"))
    }

    func testTableEmptyHeaders() {
        let result = TextFormatter.table(headers: [], rows: [], columnWidths: [])
        XCTAssertEqual(result, "")
    }

    func testTableEmptyRows() {
        let result = TextFormatter.table(
            headers: ["A", "B"],
            rows: [],
            columnWidths: [10, 10]
        )
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2, "Header + separator only")
    }

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

    // MARK: - Compact date formatting

    func testCompactDateISO8601() {
        // Use a known UTC date and verify the output matches local time
        let iso = "2025-06-15T14:30:00Z"
        let result = TextFormatter.compactDate(iso)

        // Should be in YYYY-MM-DD HH:MM format
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#
        XCTAssertNotNil(result.range(of: pattern, options: .regularExpression),
                        "Expected YYYY-MM-DD HH:MM format, got: \(result)")
    }

    func testCompactDateWithFractionalSeconds() {
        let iso = "2025-06-15T14:30:00.123Z"
        let result = TextFormatter.compactDate(iso)

        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#
        XCTAssertNotNil(result.range(of: pattern, options: .regularExpression),
                        "Expected YYYY-MM-DD HH:MM format, got: \(result)")
    }

    func testCompactDateInvalid() {
        let invalid = "not-a-date"
        XCTAssertEqual(TextFormatter.compactDate(invalid), invalid, "Invalid input returned as-is")
    }

    // MARK: - Card formatting

    func testCardFormatting() {
        let fields: [(String, String)] = [
            ("From", "alice@example.com"),
            ("Subject", "Hello"),
        ]
        let result = TextFormatter.card(fields: fields)
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("alice@example.com"))
        XCTAssertTrue(lines[1].contains("Hello"))
    }

    func testCardKeyAlignment() {
        let fields: [(String, String)] = [
            ("A", "value1"),
            ("LongKey", "value2"),
        ]
        let result = TextFormatter.card(fields: fields)
        let lines = result.components(separatedBy: "\n")
        // Both keys should be padded to the same length (7 = "LongKey".count)
        // "A      " + "  " + "value1"
        XCTAssertTrue(lines[0].hasPrefix("A       "), "Short key should be right-padded")
        XCTAssertTrue(lines[1].hasPrefix("LongKey"), "Long key should not be padded")
    }

    func testCardMultilineValue() {
        let fields: [(String, String)] = [
            ("Body", "Line one\nLine two\nLine three"),
        ]
        let result = TextFormatter.card(fields: fields)
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("Line one"))
        XCTAssertTrue(lines[1].contains("Line two"))
        XCTAssertTrue(lines[2].contains("Line three"))
    }

    func testCardEmpty() {
        XCTAssertEqual(TextFormatter.card(fields: []), "")
    }

    // MARK: - File size formatting

    func testFileSizeBytes() {
        XCTAssertEqual(TextFormatter.fileSize(512), "512B")
    }

    func testFileSizeKB() {
        XCTAssertEqual(TextFormatter.fileSize(2048), "2KB")
    }

    func testFileSizeMB() {
        let result = TextFormatter.fileSize(1_500_000)
        XCTAssertTrue(result.hasSuffix("MB"), "Expected MB suffix, got: \(result)")
        XCTAssertTrue(result.hasPrefix("1."), "Expected ~1.4MB, got: \(result)")
    }

    func testFileSizeZero() {
        XCTAssertEqual(TextFormatter.fileSize(0), "0B")
    }

    func testFileSizeExactlyOneKB() {
        XCTAssertEqual(TextFormatter.fileSize(1024), "1KB")
    }

    // MARK: - Action result

    func testActionResultSuccess() {
        let result = TextFormatter.actionResult(success: true, action: "mark", details: "readStatus=true")
        XCTAssertEqual(result, "[ok] mark: readStatus=true")
    }

    func testActionResultFailure() {
        let result = TextFormatter.actionResult(success: false, action: "send", details: "timeout")
        XCTAssertEqual(result, "[FAIL] send: timeout")
    }
}
