import EventKit
@testable import PippinLib
import XCTest

final class CalendarBridgeTests: XCTestCase {
    // MARK: - Error descriptions

    func testAccessDeniedDescription() {
        let err = CalendarBridgeError.accessDenied
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains("Calendar access denied") || desc.contains("System Settings"),
            "Expected access denied message, got: \(desc)"
        )
    }

    func testEventNotFoundDescription() {
        let err = CalendarBridgeError.eventNotFound("abc123")
        XCTAssertTrue(err.errorDescription?.contains("abc123") == true)
    }

    func testCalendarNotFoundDescription() {
        let err = CalendarBridgeError.calendarNotFound("cal-xyz")
        XCTAssertTrue(err.errorDescription?.contains("cal-xyz") == true)
    }

    func testSaveFailedDescription() {
        let err = CalendarBridgeError.saveFailed("disk full")
        XCTAssertTrue(err.errorDescription?.contains("disk full") == true)
    }

    func testAmbiguousIdDescription() {
        let err = CalendarBridgeError.ambiguousId("ab")
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("ab"), "Expected ID in message, got: \(desc)")
        XCTAssertTrue(
            desc.contains("multiple") || desc.contains("Ambiguous"),
            "Expected ambiguity message, got: \(desc)"
        )
    }

    // MARK: - mapCalendarType helper

    func testMapCalendarTypeLocal() {
        XCTAssertEqual(mapCalendarType(.local), "local")
    }

    func testMapCalendarTypeCalDAV() {
        XCTAssertEqual(mapCalendarType(.calDAV), "calDAV")
    }

    func testMapCalendarTypeExchange() {
        XCTAssertEqual(mapCalendarType(.exchange), "exchange")
    }

    func testMapCalendarTypeSubscription() {
        XCTAssertEqual(mapCalendarType(.subscription), "subscription")
    }

    func testMapCalendarTypeBirthday() {
        XCTAssertEqual(mapCalendarType(.birthday), "birthday")
    }

    // MARK: - parseCalendarDate helper

    func testParseISO8601UTC() {
        XCTAssertNotNil(parseCalendarDate("2026-03-07T10:00:00Z"))
    }

    func testParseISO8601WithOffset() {
        XCTAssertNotNil(parseCalendarDate("2026-03-07T10:00:00+05:00"))
    }

    func testParseISO8601WithNegativeOffset() {
        XCTAssertNotNil(parseCalendarDate("2026-03-07T10:00:00-07:00"))
    }

    func testParseISO8601NoTimezone() {
        let date = parseCalendarDate("2026-03-07T10:00:00")
        XCTAssertNotNil(date)
    }

    func testParseDateOnly() {
        let date = parseCalendarDate("2026-03-07")
        XCTAssertNotNil(date)
    }

    func testParseDateOnlyIsMidnight() {
        let date = parseCalendarDate("2026-03-07")
        guard let date else { return XCTFail("Failed to parse date") }
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.hour, from: date), 0)
        XCTAssertEqual(cal.component(.minute, from: date), 0)
        XCTAssertEqual(cal.component(.second, from: date), 0)
    }

    func testParseInvalidDate() {
        XCTAssertNil(parseCalendarDate("not-a-date"))
        XCTAssertNil(parseCalendarDate(""))
        XCTAssertNil(parseCalendarDate("March 7"))
        XCTAssertNil(parseCalendarDate("yesterday"))
    }

    // MARK: - colorHex helper

    func testColorHexBlack() throws {
        let black = try XCTUnwrap(CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [0, 0, 0, 1]
        ))
        XCTAssertEqual(colorHex(black), "#000000")
    }

    func testColorHexWhite() throws {
        let white = try XCTUnwrap(CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [1, 1, 1, 1]
        ))
        XCTAssertEqual(colorHex(white), "#FFFFFF")
    }

    func testColorHexRed() throws {
        let red = try XCTUnwrap(CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [1, 0, 0, 1]
        ))
        XCTAssertEqual(colorHex(red), "#FF0000")
    }

    func testColorHexGreen() throws {
        let green = try XCTUnwrap(CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [0, 1, 0, 1]
        ))
        XCTAssertEqual(colorHex(green), "#00FF00")
    }

    func testColorHexBlue() throws {
        let blue = try XCTUnwrap(CGColor(
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            components: [0, 0, 1, 1]
        ))
        XCTAssertEqual(colorHex(blue), "#0000FF")
    }

    // MARK: - formatEventDate helper

    func testFormatEventDateProducesISO8601() {
        let date = Date(timeIntervalSince1970: 0) // 1970-01-01T00:00:00Z
        let str = formatEventDate(date)
        XCTAssertTrue(str.contains("1970"), "Expected year 1970 in: \(str)")
        XCTAssertTrue(str.contains("T"), "Expected 'T' separator in ISO 8601: \(str)")
    }

    // MARK: - EventKit operations (require full access)

    func testListCalendarsRequiresAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        try XCTSkipUnless(
            status == .fullAccess || status.rawValue == 3, // .authorized deprecated
            "Calendar access not granted — skipping EventKit tests"
        )
        let bridge = CalendarBridge()
        let calendars = try await bridge.listCalendars()
        XCTAssertFalse(calendars.isEmpty, "Expected at least one calendar")
    }

    func testListEventsTodayRequiresAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        try XCTSkipUnless(
            status == .fullAccess || status.rawValue == 3,
            "Calendar access not granted — skipping EventKit tests"
        )
        let bridge = CalendarBridge()
        let start = Calendar.current.startOfDay(for: Date())
        let end = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: start))
        // Should not throw
        _ = try await bridge.listEvents(from: start, to: end)
    }

    // MARK: - parseSpan helper

    func testParseSpanThis() {
        XCTAssertEqual(parseSpan("this"), .thisEvent)
    }

    func testParseSpanFuture() {
        XCTAssertEqual(parseSpan("future"), .futureEvents)
    }

    func testParseSpanCaseInsensitive() {
        XCTAssertEqual(parseSpan("THIS"), .thisEvent)
        XCTAssertEqual(parseSpan("FUTURE"), .futureEvents)
    }

    func testParseSpanInvalid() {
        XCTAssertNil(parseSpan("all"))
        XCTAssertNil(parseSpan(""))
        XCTAssertNil(parseSpan("both"))
    }

    // MARK: - parseAlertDuration helper

    func testParseAlertDurationMinutes() {
        XCTAssertEqual(parseAlertDuration("15m"), 15 * 60)
        XCTAssertEqual(parseAlertDuration("1m"), 60)
        XCTAssertEqual(parseAlertDuration("60m"), 3600)
    }

    func testParseAlertDurationHours() {
        XCTAssertEqual(parseAlertDuration("1h"), 3600)
        XCTAssertEqual(parseAlertDuration("2h"), 7200)
    }

    func testParseAlertDurationDays() {
        XCTAssertEqual(parseAlertDuration("1d"), 86400)
        XCTAssertEqual(parseAlertDuration("2d"), 172_800)
    }

    func testParseAlertDurationInvalid() {
        XCTAssertNil(parseAlertDuration("15"))
        XCTAssertNil(parseAlertDuration(""))
        XCTAssertNil(parseAlertDuration("15x"))
        XCTAssertNil(parseAlertDuration("one hour"))
        XCTAssertNil(parseAlertDuration("h1"))
    }

    // MARK: - formatAlertOffset helper

    func testFormatAlertOffsetMinutes() {
        XCTAssertEqual(formatAlertOffset(15 * 60), "15 minutes before")
        XCTAssertEqual(formatAlertOffset(60), "1 minute before")
    }

    func testFormatAlertOffsetHours() {
        XCTAssertEqual(formatAlertOffset(3600), "1 hour before")
        XCTAssertEqual(formatAlertOffset(7200), "2 hours before")
    }

    func testFormatAlertOffsetDays() {
        XCTAssertEqual(formatAlertOffset(86400), "1 day before")
        XCTAssertEqual(formatAlertOffset(172_800), "2 days before")
    }
}
