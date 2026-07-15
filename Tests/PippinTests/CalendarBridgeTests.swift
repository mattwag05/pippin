import EventKit
@testable import PippinLib
import XCTest

final class CalendarBridgeTests: XCTestCase {
    // MARK: - Prefix match disambiguation (recurring events)

    func testPrefixMatchSingleEventIsUnambiguous() {
        XCTAssertTrue(CalendarBridge.isUnambiguousPrefixMatch(["ABC123"]))
    }

    func testPrefixMatchRecurringOccurrencesAreUnambiguous() {
        // A recurring event yields many occurrences sharing one identifier —
        // this is a single event, not an ambiguous prefix. (Regression: the
        // old count==1 check wrongly returned nil here.)
        XCTAssertTrue(CalendarBridge.isUnambiguousPrefixMatch(["EVT/0", "EVT/0", "EVT/0"]))
    }

    func testPrefixMatchDistinctIdentifiersAreAmbiguous() {
        XCTAssertFalse(CalendarBridge.isUnambiguousPrefixMatch(["EVT/0", "OTHER/9"]))
    }

    func testPrefixMatchNoCandidatesIsNotAMatch() {
        XCTAssertFalse(CalendarBridge.isUnambiguousPrefixMatch([]))
    }

    // MARK: - Date-range chunking (pippin-5nj)
    //
    // EKEventStore.predicateForEvents(withStart:end:calendars:) silently drops
    // events for windows wider than a few years. `chunkRanges` is the pure
    // splitting logic behind the fix — no live EKEventStore needed to test it.

    func testChunkRangesEmptyForEqualStartEnd() {
        let d = Date()
        XCTAssertTrue(CalendarBridge.chunkRanges(from: d, to: d).isEmpty)
    }

    func testChunkRangesEmptyForInvertedRange() {
        let start = Date()
        let end = start.addingTimeInterval(-3600)
        XCTAssertTrue(CalendarBridge.chunkRanges(from: start, to: end).isEmpty)
    }

    func testChunkRangesSingleChunkWhenUnderMax() {
        let start = Date()
        let end = start.addingTimeInterval(60 * 60 * 24 * 30) // 30 days
        let ranges = CalendarBridge.chunkRanges(from: start, to: end, maxDays: 366)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0].start, start)
        XCTAssertEqual(ranges[0].end, end)
    }

    func testChunkRangesSplitsWideRangeContiguously() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 1990, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31))!
        let ranges = CalendarBridge.chunkRanges(from: start, to: end, maxDays: 366)

        XCTAssertGreaterThan(ranges.count, 1, "37-year range must split into multiple chunks")
        XCTAssertEqual(ranges.first?.start, start, "first chunk must start at the requested start")
        XCTAssertEqual(ranges.last?.end, end, "last chunk must end exactly at the requested end")

        // Contiguous, no gaps or overlaps: each chunk's end is the next chunk's start.
        for i in 1 ..< ranges.count {
            XCTAssertEqual(ranges[i - 1].end, ranges[i].start, "chunk \(i - 1)/\(i) boundary must be contiguous")
        }
        // No chunk exceeds the max width.
        for (chunkStart, chunkEnd) in ranges {
            let days = calendar.dateComponents([.day], from: chunkStart, to: chunkEnd).day ?? 0
            XCTAssertLessThanOrEqual(days, 366)
        }
    }

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

    func testDateParseErrorDescription() {
        let err = CalendarBridgeError.dateParseError("tomorrow at noon")
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("tomorrow at noon"), "Expected input value in message, got: \(desc)")
        XCTAssertTrue(
            desc.contains("date") || desc.contains("parse"),
            "Expected parse-related message, got: \(desc)"
        )
    }

    func testAiParseErrorDescription() {
        let err = CalendarBridgeError.aiParseError("not valid json")
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("not valid json"), "Expected AI response in message, got: \(desc)")
        XCTAssertTrue(
            desc.contains("AI") || desc.contains("parsed") || desc.contains("JSON"),
            "Expected AI parse message, got: \(desc)"
        )
    }

    func testAllErrorCasesHaveDescriptions() {
        let errors: [CalendarBridgeError] = [
            .accessDenied,
            .eventNotFound("evt-1"),
            .calendarNotFound("cal-1"),
            .saveFailed("disk full"),
            .ambiguousId("ab"),
            .dateParseError("bad date"),
            .aiParseError("bad json"),
        ]
        for err in errors {
            XCTAssertNotNil(err.errorDescription, "Missing errorDescription for: \(err)")
            XCTAssertFalse(err.errorDescription?.isEmpty == true, "Empty errorDescription for: \(err)")
        }
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

    // MARK: - Space-separated + minute-precision datetimes (pippin-3gp)

    /// The headline ergonomic case: agents/humans naturally write a space
    /// between date and time, which must parse to that exact local wall-clock
    /// time (not midnight, not nil).
    func testParseSpaceSeparatedMinutePrecision() {
        guard let date = parseCalendarDate("2026-06-04 12:30") else {
            return XCTFail("Space-separated 'YYYY-MM-DD HH:MM' must parse")
        }
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.year, from: date), 2026)
        XCTAssertEqual(cal.component(.month, from: date), 6)
        XCTAssertEqual(cal.component(.day, from: date), 4)
        XCTAssertEqual(cal.component(.hour, from: date), 12)
        XCTAssertEqual(cal.component(.minute, from: date), 30)
    }

    func testParseSpaceSeparatedWithSeconds() {
        guard let date = parseCalendarDate("2026-06-04 12:30:45") else {
            return XCTFail("Space-separated 'YYYY-MM-DD HH:MM:SS' must parse")
        }
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.hour, from: date), 12)
        XCTAssertEqual(cal.component(.minute, from: date), 30)
        XCTAssertEqual(cal.component(.second, from: date), 45)
    }

    /// `T`-separated without seconds was also rejected before — round it out.
    func testParseTSeparatedMinutePrecision() {
        guard let date = parseCalendarDate("2026-06-04T12:30") else {
            return XCTFail("'YYYY-MM-DDTHH:MM' must parse")
        }
        XCTAssertEqual(Calendar.current.component(.minute, from: date), 30)
    }

    /// Space-separated and `T`-separated minute-precision must denote the SAME
    /// instant — i.e. the space form is just sugar for local-time ISO.
    func testParseSpaceAndTSeparatedAgree() {
        XCTAssertEqual(
            parseCalendarDate("2026-06-04 12:30"),
            parseCalendarDate("2026-06-04T12:30")
        )
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

    // MARK: - formatEventDay (all-day date-only serialization)

    func testFormatEventDayEmitsLocalCalendarDay() {
        // Midnight LOCAL on Jul 23 must serialize as 2026-07-23 regardless of
        // the machine's UTC offset (the old UTC-instant form shifted the day
        // for positive-offset consumers).
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 23))!
        XCTAssertEqual(formatEventDay(date), "2026-07-23")
    }

    func testFormatEventDayRoundTripsThroughParseCalendarDate() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 23))!
        XCTAssertEqual(parseCalendarDate(formatEventDay(date)), date)
    }

    // MARK: - calendarIdMissDetail (--calendar ID-vs-name hint)

    func testCalendarIdMissDetailPlainWhenNoNameMatches() {
        XCTAssertEqual(CalendarBridge.calendarIdMissDetail("ZZZ", matchingIds: []), "ZZZ")
    }

    func testCalendarIdMissDetailHintsRealId() {
        let detail = CalendarBridge.calendarIdMissDetail("Family", matchingIds: ["ABC-123"])
        XCTAssertTrue(detail.contains("ABC-123"))
        XCTAssertTrue(detail.contains("pippin calendar list"))
    }

    func testCalendarIdMissDetailListsAllAmbiguousIds() {
        let detail = CalendarBridge.calendarIdMissDetail("Family", matchingIds: ["ID-1", "ID-2"])
        XCTAssertTrue(detail.contains("ID-1"))
        XCTAssertTrue(detail.contains("ID-2"))
    }
}
