@testable import PippinLib
import XCTest

/// RC-17: every occurrence of a recurring event shares one id, so an id alone
/// must never choose which occurrence an edit or delete hits. These cover the
/// pure decision and matching logic; EventKit itself is not exercised.
final class EventTargetingTests: XCTestCase {
    private let id = "4F2A9C10-1111-4AAA-8AAA-000000000001"
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// A weekly series, Mondays 15:00 UTC.
    private var weekly: [Date] {
        ["2026-11-02T15:00:00Z", "2026-11-09T15:00:00Z", "2026-11-16T15:00:00Z"].map(date)
    }

    private func target(
        recurring: Bool, occurrence: OccurrenceSpec? = nil, span: EventSpan = .this, mutating: Bool = true
    ) throws -> OccurrenceTarget {
        try occurrenceTarget(id: id, isRecurring: recurring, occurrence: occurrence, span: span, mutating: mutating)
    }

    // MARK: - occurrenceTarget

    func testNonRecurringEventNeverNeedsAnOccurrence() throws {
        let spec = OccurrenceSpec(date: date("2026-11-09T15:00:00Z"), dayOnly: false)
        for span in [EventSpan.this, .future, .all] {
            for mutating in [true, false] {
                XCTAssertEqual(try target(recurring: false, span: span, mutating: mutating), .item)
                // A caller that always passes the occurrence is not punished.
                XCTAssertEqual(try target(recurring: false, occurrence: spec, span: span, mutating: mutating), .item)
            }
        }
    }

    func testRecurringMutationWithoutOccurrenceIsRefused() {
        // `future` counts too: from the id alone it would start at the series'
        // first occurrence and take the whole series with it.
        for span in [EventSpan.this, .future] {
            XCTAssertThrowsError(try target(recurring: true, span: span), "span \(span)") { error in
                guard case let CalendarBridgeError.occurrenceRequired(refused) = error else {
                    return XCTFail("Expected occurrenceRequired, got \(error)")
                }
                XCTAssertEqual(refused, id)
            }
        }
    }

    func testOccurrenceRequiredErrorTellsTheCallerWhatToPass() throws {
        let error = CalendarBridgeError.occurrenceRequired(id)
        XCTAssertEqual(agentErrorCode(for: error), "occurrence_required")
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("--occurrence"))
        XCTAssertTrue(message.contains("--span all"))
        // The next call is the one whose rows carry the value for the flag.
        let call = try XCTUnwrap(error.nextStep.nextCall)
        XCTAssertEqual(call.tool, "calendar_events")
        XCTAssertTrue(call.argv.joined(separator: " ").contains("occurrenceDate"))
        XCTAssertFalse(error.nextStep.retryable)
    }

    func testRecurringMutationWithWholeSeriesSpanProceeds() throws {
        XCTAssertEqual(try target(recurring: true, span: .all), .item)
    }

    func testRecurringMutationWithOccurrenceTargetsThatOccurrence() throws {
        let spec = OccurrenceSpec(date: date("2026-11-09T15:00:00Z"), dayOnly: false)
        XCTAssertEqual(try target(recurring: true, occurrence: spec, span: .this), .occurrence(spec))
        XCTAssertEqual(try target(recurring: true, occurrence: spec, span: .future), .occurrence(spec))
    }

    func testRecurringReadWithoutOccurrenceStillWorks() throws {
        let spec = OccurrenceSpec(date: date("2026-11-09T15:00:00Z"), dayOnly: false)
        XCTAssertEqual(try target(recurring: true, mutating: false), .item)
        XCTAssertEqual(try target(recurring: true, occurrence: spec, mutating: false), .occurrence(spec))
    }

    // MARK: - OccurrenceSpec parsing

    func testOccurrenceSpecParsing() throws {
        let stamp = try XCTUnwrap(OccurrenceSpec(argument: "2026-11-09T15:00:00Z"))
        XCTAssertFalse(stamp.dayOnly)
        XCTAssertEqual(stamp.date, date("2026-11-09T15:00:00Z"))
        XCTAssertTrue(try XCTUnwrap(OccurrenceSpec(argument: "2026-11-09")).dayOnly)
        XCTAssertFalse(try XCTUnwrap(OccurrenceSpec(argument: "2026-11-09 15:00")).dayOnly)
        XCTAssertNil(OccurrenceSpec(argument: "next monday"))
        XCTAssertNil(OccurrenceSpec(argument: ""))
    }

    // MARK: - Picking the occurrence

    func testTimestampPicksExactlyThatOccurrence() throws {
        let spec = OccurrenceSpec(date: weekly[1], dayOnly: false)
        XCTAssertEqual(try spec.pick(from: weekly, id: id, calendar: utc), 1)
        // The regression: the first occurrence is NOT what the caller named.
        XCTAssertNotEqual(try spec.pick(from: weekly, id: id, calendar: utc), 0)
    }

    func testTimestampThatIsNoOccurrenceIsNotFound() {
        // Right weekday and series, wrong time: must not round to a neighbor.
        let spec = OccurrenceSpec(date: date("2026-11-09T16:00:00Z"), dayOnly: false)
        XCTAssertThrowsError(try spec.pick(from: weekly, id: id, calendar: utc)) { error in
            guard case CalendarBridgeError.occurrenceNotFound = error else {
                return XCTFail("Expected occurrenceNotFound, got \(error)")
            }
            XCTAssertEqual(agentErrorCode(for: error), "occurrence_not_found")
            XCTAssertEqual(PippinExitCode.from(error), 3)
        }
        XCTAssertThrowsError(try spec.pick(from: [], id: id, calendar: utc))
    }

    func testDayPicksTheOccurrenceOnThatDay() throws {
        let spec = OccurrenceSpec(date: date("2026-11-16T00:00:00Z"), dayOnly: true)
        XCTAssertEqual(try spec.pick(from: weekly, id: id, calendar: utc), 2)
        let empty = OccurrenceSpec(date: date("2026-11-10T00:00:00Z"), dayOnly: true)
        XCTAssertThrowsError(try empty.pick(from: weekly, id: id, calendar: utc))
    }

    func testDayWithTwoOccurrencesIsRefusedNotGuessed() {
        let twiceDaily = ["2026-11-09T09:00:00Z", "2026-11-09T15:00:00Z"].map(date)
        let spec = OccurrenceSpec(date: date("2026-11-09T00:00:00Z"), dayOnly: true)
        XCTAssertThrowsError(try spec.pick(from: twiceDaily, id: id, calendar: utc)) { error in
            XCTAssertTrue(error.localizedDescription.contains("2 occurrences"), error.localizedDescription)
        }
    }

    func testDayBoundariesAreHalfOpen() {
        let spec = OccurrenceSpec(date: date("2026-11-09T00:00:00Z"), dayOnly: true)
        XCTAssertTrue(spec.matches(start: date("2026-11-09T00:00:00Z"), calendar: utc))
        XCTAssertTrue(spec.matches(start: date("2026-11-09T23:59:59Z"), calendar: utc))
        XCTAssertFalse(spec.matches(start: date("2026-11-10T00:00:00Z"), calendar: utc))
        XCTAssertFalse(spec.matches(start: date("2026-11-08T23:59:59Z"), calendar: utc))
    }

    func testQueryWindowContainsTheOccurrence() {
        let stamp = OccurrenceSpec(date: weekly[1], dayOnly: false).window(calendar: utc)
        XCTAssertTrue(stamp.start < weekly[1] && weekly[1] < stamp.end)
        XCTAssertLessThan(stamp.end.timeIntervalSince(stamp.start), 3600, "must not reach a neighboring occurrence")
        let day = OccurrenceSpec(date: date("2026-11-09T00:00:00Z"), dayOnly: true).window(calendar: utc)
        XCTAssertEqual(day.start, date("2026-11-09T00:00:00Z"))
        XCTAssertEqual(day.end, date("2026-11-10T00:00:00Z"))
    }

    /// The value a list row emits as `occurrenceDate` must select that same
    /// occurrence when passed back, for timed and all-day events alike.
    func testEmittedOccurrenceDateRoundTrips() throws {
        let timed = weekly[1]
        let timedSpec = try XCTUnwrap(OccurrenceSpec(argument: formatEventDate(timed)))
        XCTAssertEqual(try timedSpec.pick(from: weekly, id: id), 1)

        // All-day events start at LOCAL midnight and serialize date-only.
        let local = Calendar.current
        let allDay = (0 ..< 3).map { local.date(byAdding: .day, value: 7 * $0, to: local.startOfDay(for: timed))! }
        let daySpec = try XCTUnwrap(OccurrenceSpec(argument: formatEventDay(allDay[2])))
        XCTAssertTrue(daySpec.dayOnly)
        XCTAssertEqual(try daySpec.pick(from: allDay, id: id), 2)
    }

    // MARK: - Row shape

    func testRecurringRowCarriesOccurrenceIdentityAndPlainRowIsUnchanged() throws {
        func keys(_ event: CalendarEvent) throws -> Set<String> {
            try Set(XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any]).keys)
        }
        let plain = CalendarEvent(
            id: id, calendarId: "c", calendarTitle: "C", title: "t", startDate: "s", endDate: "e", isAllDay: false,
            isRecurring: false
        )
        XCTAssertFalse(try keys(plain).contains("occurrenceDate"))
        let recurring = CalendarEvent(
            id: id, calendarId: "c", calendarTitle: "C", title: "t", startDate: "s", endDate: "e", isAllDay: false,
            isRecurring: true, occurrenceDate: "s"
        )
        XCTAssertTrue(try keys(recurring).isSuperset(of: ["isRecurring", "occurrenceDate"]))
        XCTAssertTrue(CalendarEvent.essentialFields.contains("occurrenceDate"), "default list rows must show it")
        // Rows written before the fields existed still decode.
        let old = #"{"id":"1","calendarId":"c","calendarTitle":"C","title":"t","startDate":"s","endDate":"e","isAllDay":false,"status":"none"}"#
        XCTAssertNil(try JSONDecoder().decode(CalendarEvent.self, from: Data(old.utf8)).occurrenceDate)
    }

    // MARK: - CLI and MCP surface

    func testEditAndDeleteAcceptOccurrenceAndWholeSeriesSpan() throws {
        XCTAssertNoThrow(try CalendarCommand.Delete.parse([id, "--force", "--occurrence", "2026-11-09T15:00:00Z"]))
        XCTAssertNoThrow(try CalendarCommand.Delete.parse([id, "--force", "--span", "future", "--occurrence", "2026-11-09"]))
        XCTAssertNoThrow(try CalendarCommand.Delete.parse([id, "--force", "--span", "all"]))
        XCTAssertNoThrow(try CalendarCommand.Edit.parse([id, "--title", "x", "--occurrence", "2026-11-09T15:00:00Z"]))
        XCTAssertNoThrow(try CalendarCommand.Edit.parse([id, "--title", "x", "--span", "all"]))
        XCTAssertNoThrow(try CalendarCommand.Show.parse([id, "--occurrence", "2026-11-09"]))
        // Existing invocations still parse.
        XCTAssertNoThrow(try CalendarCommand.Delete.parse([id, "--force", "--span", "future"]))
        XCTAssertNoThrow(try CalendarCommand.Edit.parse([id, "--title", "x", "--span", "this"]))
    }

    func testBadOccurrenceAndContradictorySpanAreUsageErrors() {
        XCTAssertThrowsError(try CalendarCommand.Delete.parse([id, "--force", "--occurrence", "soon"]))
        XCTAssertThrowsError(try CalendarCommand.Edit.parse([id, "--occurrence", "soon"]))
        XCTAssertThrowsError(try CalendarCommand.Show.parse([id, "--occurrence", "soon"]))
        // "The whole series" and "this one occurrence" cannot both be meant.
        XCTAssertThrowsError(try CalendarCommand.Delete.parse([id, "--force", "--span", "all", "--occurrence", "2026-11-09"]))
        XCTAssertThrowsError(try CalendarCommand.Delete.parse([id, "--force", "--span", "sometimes"]))
    }

    func testMCPCalendarToolsForwardOccurrence() throws {
        let occurrence = "2026-11-09T15:00:00Z"
        let base: [String: JSONValue] = ["id": .string(id), "occurrence": .string(occurrence)]
        for (name, extra) in [
            ("calendar_show", [String: JSONValue]()),
            ("calendar_edit", ["title": .string("x")]),
            ("calendar_delete", ["confirm": .bool(true)]),
        ] {
            let tool = try XCTUnwrap(MCPToolRegistry.tool(named: name))
            let argv = try tool.buildArgs(.object(base.merging(extra) { $1 }))
            XCTAssertTrue(argv.contains("--occurrence=\(occurrence)"), "\(name): \(argv)")
        }
    }
}
