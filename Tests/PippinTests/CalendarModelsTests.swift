@testable import PippinLib
import XCTest

final class CalendarModelsTests: XCTestCase {
    // MARK: - CalendarInfo

    func testCalendarInfoRoundTrip() throws {
        let info = CalendarInfo(
            id: "abc-123",
            title: "Work",
            type: "calDAV",
            color: "#FF5733",
            account: "iCloud"
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(CalendarInfo.self, from: data)
        XCTAssertEqual(decoded.id, info.id)
        XCTAssertEqual(decoded.title, info.title)
        XCTAssertEqual(decoded.type, info.type)
        XCTAssertEqual(decoded.color, info.color)
        XCTAssertEqual(decoded.account, info.account)
    }

    func testCalendarInfoSendable() {
        // Verifies Sendable conformance compiles (no runtime assertion)
        let info = CalendarInfo(id: "x", title: "x", type: "local", color: "#000000", account: "x")
        let _: any Sendable = info
    }

    // MARK: - CalendarEvent

    func testCalendarEventRoundTrip() throws {
        let event = CalendarEvent(
            id: "event-id-123",
            calendarId: "cal-id",
            calendarTitle: "Personal",
            title: "Team meeting",
            startDate: "2026-03-07T10:00:00Z",
            endDate: "2026-03-07T11:00:00Z",
            isAllDay: false,
            location: "Conference Room A",
            notes: "Bring laptop",
            url: "https://zoom.us/j/12345",
            attendees: [
                Attendee(name: "Alice", email: "alice@example.com", status: "accepted"),
            ],
            recurrence: "weekly",
            status: "confirmed"
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: data)
        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.title, event.title)
        XCTAssertEqual(decoded.isAllDay, false)
        XCTAssertEqual(decoded.location, "Conference Room A")
        XCTAssertEqual(decoded.notes, "Bring laptop")
        XCTAssertEqual(decoded.url, "https://zoom.us/j/12345")
        XCTAssertEqual(decoded.attendees?.count, 1)
        XCTAssertEqual(decoded.attendees?.first?.name, "Alice")
        XCTAssertEqual(decoded.attendees?.first?.status, "accepted")
        XCTAssertEqual(decoded.recurrence, "weekly")
        XCTAssertEqual(decoded.status, "confirmed")
    }

    func testCalendarEventMinimalDefaults() throws {
        let event = CalendarEvent(
            id: "minimal",
            calendarId: "cal",
            calendarTitle: "Work",
            title: "Standup",
            startDate: "2026-03-07T09:00:00Z",
            endDate: "2026-03-07T09:30:00Z",
            isAllDay: false
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: data)
        XCTAssertNil(decoded.location)
        XCTAssertNil(decoded.notes)
        XCTAssertNil(decoded.url)
        XCTAssertNil(decoded.attendees)
        XCTAssertNil(decoded.recurrence)
        XCTAssertEqual(decoded.status, "none")
    }

    func testCalendarEventAllDayFlag() throws {
        let event = CalendarEvent(
            id: "allday",
            calendarId: "cal",
            calendarTitle: "Personal",
            title: "Holiday",
            startDate: "2026-12-25T00:00:00Z",
            endDate: "2026-12-26T00:00:00Z",
            isAllDay: true
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: data)
        XCTAssertTrue(decoded.isAllDay)
    }

    // MARK: - Attendee

    func testAttendeeRoundTrip() throws {
        let attendee = Attendee(name: "Bob", email: "bob@example.com", status: "tentative")
        let data = try JSONEncoder().encode(attendee)
        let decoded = try JSONDecoder().decode(Attendee.self, from: data)
        XCTAssertEqual(decoded.name, "Bob")
        XCTAssertEqual(decoded.email, "bob@example.com")
        XCTAssertEqual(decoded.status, "tentative")
    }

    func testAttendeeNilFields() throws {
        let attendee = Attendee(name: nil, email: nil, status: "pending")
        let data = try JSONEncoder().encode(attendee)
        let decoded = try JSONDecoder().decode(Attendee.self, from: data)
        XCTAssertNil(decoded.name)
        XCTAssertNil(decoded.email)
        XCTAssertEqual(decoded.status, "pending")
    }

    func testAttendeeAllStatuses() throws {
        let statuses = ["accepted", "declined", "tentative", "pending"]
        for status in statuses {
            let a = Attendee(name: "Test", email: nil, status: status)
            let data = try JSONEncoder().encode(a)
            let decoded = try JSONDecoder().decode(Attendee.self, from: data)
            XCTAssertEqual(decoded.status, status)
        }
    }

    // MARK: - CalendarActionResult

    func testCalendarActionResultRoundTrip() throws {
        let result = CalendarActionResult(
            success: true,
            action: "create",
            details: ["id": "abc123", "title": "Team meeting"]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CalendarActionResult.self, from: data)
        XCTAssertTrue(decoded.success)
        XCTAssertEqual(decoded.action, "create")
        XCTAssertEqual(decoded.details["id"], "abc123")
        XCTAssertEqual(decoded.details["title"], "Team meeting")
    }

    func testCalendarActionResultFailure() throws {
        let result = CalendarActionResult(
            success: false,
            action: "delete",
            details: ["error": "not found"]
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CalendarActionResult.self, from: data)
        XCTAssertFalse(decoded.success)
        XCTAssertEqual(decoded.action, "delete")
    }

    // MARK: - alerts field

    func testCalendarEventWithAlertsRoundTrip() throws {
        let event = CalendarEvent(
            id: "alerted",
            calendarId: "cal",
            calendarTitle: "Work",
            title: "Team standup",
            startDate: "2026-03-07T09:00:00Z",
            endDate: "2026-03-07T09:30:00Z",
            isAllDay: false,
            alerts: ["15 minutes before", "1 hour before"]
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: data)
        XCTAssertEqual(decoded.alerts?.count, 2)
        XCTAssertEqual(decoded.alerts?.first, "15 minutes before")
        XCTAssertEqual(decoded.alerts?.last, "1 hour before")
    }

    func testCalendarEventAlertsNilByDefault() throws {
        let event = CalendarEvent(
            id: "no-alert",
            calendarId: "cal",
            calendarTitle: "Personal",
            title: "Lunch",
            startDate: "2026-03-07T12:00:00Z",
            endDate: "2026-03-07T13:00:00Z",
            isAllDay: false
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: data)
        XCTAssertNil(decoded.alerts)
    }

    // MARK: - Date format preservation

    func testEventDatesPreservedAsStrings() throws {
        let startISO = "2026-03-07T10:00:00Z"
        let endISO = "2026-03-07T11:00:00Z"
        let event = CalendarEvent(
            id: "x", calendarId: "y", calendarTitle: "Z",
            title: "Test",
            startDate: startISO,
            endDate: endISO,
            isAllDay: false
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(CalendarEvent.self, from: data)
        XCTAssertEqual(decoded.startDate, startISO)
        XCTAssertEqual(decoded.endDate, endISO)
    }
}
