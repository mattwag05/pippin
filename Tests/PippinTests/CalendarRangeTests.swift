@testable import PippinLib
import XCTest

final class CalendarRangeTests: XCTestCase {
    // MARK: - parseRange helper

    func testParseTodayRange() throws {
        let cal = Calendar.current
        let now = Date()
        let expectedStart = cal.startOfDay(for: now)
        let expectedEnd = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: expectedStart))

        guard let (start, end) = parseRange("today") else {
            return XCTFail("parseRange(\"today\") returned nil")
        }
        XCTAssertEqual(start, expectedStart, "start should be start of today")
        XCTAssertEqual(end, expectedEnd, "end should be start of tomorrow (midnight)")
    }

    func testParseTodayPlus3() throws {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        // today+3 spans today through end of day+3, so 4 days: today, +1, +2, +3
        let expectedEnd = try XCTUnwrap(cal.date(byAdding: .day, value: 4, to: today))

        guard let (start, end) = parseRange("today+3") else {
            return XCTFail("parseRange(\"today+3\") returned nil")
        }
        XCTAssertEqual(start, today, "start should be start of today")
        XCTAssertEqual(end, expectedEnd, "end should be start of day 4 days from today")
    }

    func testParseWeek() throws {
        let cal = Calendar.current
        let now = Date()
        let expectedStart = try XCTUnwrap(cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)))
        let expectedEnd = try XCTUnwrap(cal.date(byAdding: .weekOfYear, value: 1, to: expectedStart))

        guard let (start, end) = parseRange("week") else {
            return XCTFail("parseRange(\"week\") returned nil")
        }
        XCTAssertEqual(start, expectedStart, "start should be start of current week")
        XCTAssertEqual(end, expectedEnd, "end should be start of next week")
    }

    func testParseMonth() throws {
        let cal = Calendar.current
        let now = Date()
        let expectedStart = try XCTUnwrap(cal.date(from: cal.dateComponents([.year, .month], from: now)))
        let expectedEnd = try XCTUnwrap(cal.date(byAdding: .month, value: 1, to: expectedStart))

        guard let (start, end) = parseRange("month") else {
            return XCTFail("parseRange(\"month\") returned nil")
        }
        XCTAssertEqual(start, expectedStart, "start should be start of current month")
        XCTAssertEqual(end, expectedEnd, "end should be start of next month")
    }

    func testParseUnknown() {
        XCTAssertNil(parseRange("yesterday"), "\"yesterday\" should return nil")
        XCTAssertNil(parseRange(""), "empty string should return nil")
        XCTAssertNil(parseRange("today+0"), "today+0 should return nil (n must be > 0)")
        XCTAssertNil(parseRange("today+-1"), "today+-1 should return nil")
        XCTAssertNil(parseRange("next week"), "unrecognized shorthand should return nil")
    }

    // MARK: - parseRange case insensitivity

    func testParseTodayUppercase() {
        XCTAssertNotNil(parseRange("TODAY"), "should be case-insensitive")
        XCTAssertNotNil(parseRange("Today"), "should be case-insensitive")
    }

    func testParseWeekUppercase() {
        XCTAssertNotNil(parseRange("WEEK"), "should be case-insensitive")
    }

    func testParseMonthUppercase() {
        XCTAssertNotNil(parseRange("MONTH"), "should be case-insensitive")
    }

    // MARK: - CalendarCommand.Events --range validation

    func testEventsRangeValidShorthandsPasses() {
        XCTAssertNoThrow(try CalendarCommand.Events.parse(["--range", "today"]))
        XCTAssertNoThrow(try CalendarCommand.Events.parse(["--range", "week"]))
        XCTAssertNoThrow(try CalendarCommand.Events.parse(["--range", "month"]))
        XCTAssertNoThrow(try CalendarCommand.Events.parse(["--range", "today+3"]))
        XCTAssertNoThrow(try CalendarCommand.Events.parse(["--range", "today+14"]))
    }

    func testEventsRangeInvalidShorthandFails() {
        XCTAssertThrowsError(try CalendarCommand.Events.parse(["--range", "yesterday"]))
        XCTAssertThrowsError(try CalendarCommand.Events.parse(["--range", "today+0"]))
        XCTAssertThrowsError(try CalendarCommand.Events.parse(["--range", "next week"]))
    }

    // MARK: - CalendarCommand convenience aliases parse correctly

    func testTodaySubcommandParsesWithNoArgs() {
        XCTAssertNoThrow(try CalendarCommand.Today.parse([]))
    }

    func testTodaySubcommandParsesWithJsonFormat() {
        XCTAssertNoThrow(try CalendarCommand.Today.parse(["--format", "json"]))
    }

    func testRemainingSubcommandParsesWithNoArgs() {
        XCTAssertNoThrow(try CalendarCommand.Remaining.parse([]))
    }

    func testUpcomingSubcommandParsesWithNoArgs() {
        XCTAssertNoThrow(try CalendarCommand.Upcoming.parse([]))
    }

    func testUpcomingSubcommandParsesWithFieldsAndFormat() {
        XCTAssertNoThrow(try CalendarCommand.Upcoming.parse(["--fields", "title,startDate", "--format", "json"]))
    }
}
