@testable import PippinLib
import XCTest

/// `--fields` projection of calendar events through `FieldProjection`, the
/// path `OutputOptions.printAgent` uses.
final class CalendarFieldFilteringTests: XCTestCase {
    // MARK: - Fixture

    private func makeEvent() -> CalendarEvent {
        CalendarEvent(
            id: "event-abc123",
            calendarId: "cal-id",
            calendarTitle: "Work",
            title: "Team Meeting",
            startDate: "2026-03-10T10:00:00Z",
            endDate: "2026-03-10T11:00:00Z",
            isAllDay: false,
            location: "Room A",
            notes: "Agenda attached"
        )
    }

    private func encodedDict(_ event: CalendarEvent) throws -> [String: Any] {
        let data = try JSONEncoder().encode(event)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Test 1: unprojected encoding carries every field

    func testEncodingReturnsAllFields() throws {
        let dict = try encodedDict(makeEvent())
        // nil optional fields are omitted by JSONEncoder
        XCTAssertEqual(dict["id"] as? String, "event-abc123")
        XCTAssertEqual(dict["title"] as? String, "Team Meeting")
        XCTAssertEqual(dict["calendarId"] as? String, "cal-id")
        XCTAssertEqual(dict["calendarTitle"] as? String, "Work")
        XCTAssertEqual(dict["startDate"] as? String, "2026-03-10T10:00:00Z")
        XCTAssertEqual(dict["endDate"] as? String, "2026-03-10T11:00:00Z")
        XCTAssertNotNil(dict["isAllDay"])
        XCTAssertEqual(dict["location"] as? String, "Room A")
        XCTAssertEqual(dict["notes"] as? String, "Agenda attached")
        XCTAssertNotNil(dict["status"])
    }

    // MARK: - Test 2: specific fields returns only those keys

    func testProjectionSpecificFieldsReturnsOnlyThoseKeys() throws {
        let projected = try FieldProjection.projectedObject(makeEvent(), fields: ["title", "startDate"])
        let dict = try XCTUnwrap(projected as? [String: Any])
        XCTAssertEqual(dict.count, 2)
        XCTAssertEqual(dict["title"] as? String, "Team Meeting")
        XCTAssertEqual(dict["startDate"] as? String, "2026-03-10T10:00:00Z")
        XCTAssertNil(dict["id"])
        XCTAssertNil(dict["endDate"])
        XCTAssertNil(dict["calendarTitle"])
    }

    // MARK: - Test 3: nonexistent field is silently skipped

    func testProjectionSkipsMissingFields() throws {
        let projected = try FieldProjection.projectedObject(makeEvent(), fields: ["title", "nonexistentField"])
        let dict = try XCTUnwrap(projected as? [String: Any])
        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict["title"] as? String, "Team Meeting")
        XCTAssertNil(dict["nonexistentField"])
    }

    // MARK: - Test 4: array projection filters each event

    func testArrayProjectionFiltersEachEvent() throws {
        let event1 = CalendarEvent(
            id: "e1",
            calendarId: "cal",
            calendarTitle: "Personal",
            title: "Lunch",
            startDate: "2026-03-10T12:00:00Z",
            endDate: "2026-03-10T13:00:00Z",
            isAllDay: false
        )
        let event2 = CalendarEvent(
            id: "e2",
            calendarId: "cal",
            calendarTitle: "Work",
            title: "Standup",
            startDate: "2026-03-10T09:00:00Z",
            endDate: "2026-03-10T09:15:00Z",
            isAllDay: false
        )
        let projected = try FieldProjection.projectedObject([event1, event2], fields: ["title"])
        let arr = try XCTUnwrap(projected as? [[String: Any]])
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0]["title"] as? String, "Lunch")
        XCTAssertEqual(arr[1]["title"] as? String, "Standup")
        XCTAssertNil(arr[0]["id"])
        XCTAssertNil(arr[1]["startDate"])
    }

    // MARK: - Test 5: field names are camelCase (not snake_case)

    func testFieldNamesAreCamelCase() throws {
        let dict = try encodedDict(makeEvent())
        // camelCase keys must exist
        XCTAssertNotNil(dict["startDate"], "Expected camelCase key 'startDate'")
        XCTAssertNotNil(dict["calendarId"], "Expected camelCase key 'calendarId'")
        XCTAssertNotNil(dict["isAllDay"], "Expected camelCase key 'isAllDay'")
        // snake_case keys must NOT exist
        XCTAssertNil(dict["start_date"], "snake_case key 'start_date' should not exist")
        XCTAssertNil(dict["calendar_id"], "snake_case key 'calendar_id' should not exist")
        XCTAssertNil(dict["is_all_day"], "snake_case key 'is_all_day' should not exist")
    }
}
