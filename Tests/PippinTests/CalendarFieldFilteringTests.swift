@testable import PippinLib
import XCTest

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

    // MARK: - Test 1: nil fields returns all fields

    func testJsonDataNilFieldsReturnsAllFields() throws {
        let event = makeEvent()
        let data = try event.jsonData(fields: nil)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // CalendarEvent has 14 defined properties; nil optional fields are omitted by JSONEncoder
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

    func testJsonDataSpecificFieldsReturnsOnlyThoseKeys() throws {
        let event = makeEvent()
        let data = try event.jsonData(fields: ["title", "startDate"])
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict.count, 2)
        XCTAssertEqual(dict["title"] as? String, "Team Meeting")
        XCTAssertEqual(dict["startDate"] as? String, "2026-03-10T10:00:00Z")
        XCTAssertNil(dict["id"])
        XCTAssertNil(dict["endDate"])
        XCTAssertNil(dict["calendarTitle"])
    }

    // MARK: - Test 3: nonexistent field is silently skipped

    func testJsonDataSkipsMissingFields() throws {
        let event = makeEvent()
        let data = try event.jsonData(fields: ["title", "nonexistentField"])
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict["title"] as? String, "Team Meeting")
        XCTAssertNil(dict["nonexistentField"])
    }

    // MARK: - Test 4: array filtering returns array of filtered dicts

    func testArrayJsonDataFiltersEachEvent() throws {
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
        let events = [event1, event2]
        let data = try events.jsonData(fields: ["title"])
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0]["title"] as? String, "Lunch")
        XCTAssertEqual(arr[1]["title"] as? String, "Standup")
        XCTAssertNil(arr[0]["id"])
        XCTAssertNil(arr[1]["startDate"])
    }

    // MARK: - Test 5: field names are camelCase (not snake_case)

    func testFieldNamesAreCamelCase() throws {
        let event = makeEvent()
        let data = try event.jsonData(fields: nil)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
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
