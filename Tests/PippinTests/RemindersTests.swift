import EventKit
@testable import PippinLib
import XCTest

final class RemindersTests: XCTestCase {
    // MARK: - RemindersBridgeError descriptions

    func testAccessDeniedDescription() {
        let err = RemindersBridgeError.accessDenied
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(
            desc.contains("Reminders access denied") || desc.contains("System Settings"),
            "Expected access denied message, got: \(desc)"
        )
    }

    func testReminderNotFoundDescription() {
        let err = RemindersBridgeError.reminderNotFound("abc123")
        XCTAssertTrue(err.errorDescription?.contains("abc123") == true)
    }

    func testListNotFoundDescription() {
        let err = RemindersBridgeError.listNotFound("list-xyz")
        XCTAssertTrue(err.errorDescription?.contains("list-xyz") == true)
    }

    func testSaveFailedDescription() {
        let err = RemindersBridgeError.saveFailed("disk full")
        XCTAssertTrue(err.errorDescription?.contains("disk full") == true)
    }

    func testAmbiguousIdDescription() {
        let err = RemindersBridgeError.ambiguousId("ab")
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("ab"), "Expected ID in message, got: \(desc)")
        XCTAssertTrue(
            desc.contains("multiple") || desc.contains("Ambiguous"),
            "Expected ambiguity message, got: \(desc)"
        )
    }

    // MARK: - ReminderItem Codable roundtrip

    func testReminderItemCodableRoundtrip() throws {
        let original = ReminderItem(
            id: "test-id-1",
            listId: "list-id-1",
            listTitle: "Groceries",
            title: "Buy groceries",
            notes: "Milk, eggs, bread",
            url: "https://example.com",
            isCompleted: false,
            completionDate: nil,
            dueDate: "2026-03-15T10:00:00Z",
            priority: 1,
            creationDate: "2026-03-10T08:00:00Z",
            lastModifiedDate: "2026-03-10T08:00:00Z"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderItem.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.listId, original.listId)
        XCTAssertEqual(decoded.listTitle, original.listTitle)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.notes, original.notes)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.isCompleted, original.isCompleted)
        XCTAssertEqual(decoded.dueDate, original.dueDate)
        XCTAssertEqual(decoded.priority, original.priority)
        XCTAssertEqual(decoded.creationDate, original.creationDate)
    }

    func testReminderItemMinimalCodable() throws {
        let original = ReminderItem(id: "r1", listId: "l1", listTitle: "Tasks", title: "Do laundry")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderItem.self, from: data)
        XCTAssertEqual(decoded.id, "r1")
        XCTAssertEqual(decoded.title, "Do laundry")
        XCTAssertNil(decoded.notes)
        XCTAssertNil(decoded.dueDate)
        XCTAssertFalse(decoded.isCompleted)
        XCTAssertEqual(decoded.priority, 0)
    }

    // MARK: - ReminderList Codable roundtrip

    func testReminderListCodableRoundtrip() throws {
        let original = ReminderList(
            id: "list-abc",
            title: "Groceries",
            color: "#FF0000",
            account: "iCloud",
            isDefault: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderList.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.color, original.color)
        XCTAssertEqual(decoded.account, original.account)
        XCTAssertEqual(decoded.isDefault, original.isDefault)
    }

    func testReminderListNonDefault() throws {
        let original = ReminderList(id: "l2", title: "Work", color: "#0000FF", account: "Exchange", isDefault: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderList.self, from: data)
        XCTAssertFalse(decoded.isDefault)
    }

    // MARK: - ReminderActionResult Codable roundtrip

    func testReminderActionResultCodableRoundtrip() throws {
        let original = ReminderActionResult(
            success: true,
            action: "create",
            details: ["id": "reminder-id", "title": "Call dentist"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderActionResult.self, from: data)
        XCTAssertEqual(decoded.success, original.success)
        XCTAssertEqual(decoded.action, original.action)
        XCTAssertEqual(decoded.details["id"], "reminder-id")
        XCTAssertEqual(decoded.details["title"], "Call dentist")
    }

    func testReminderActionResultFailure() throws {
        let original = ReminderActionResult(success: false, action: "delete", details: ["error": "not found"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReminderActionResult.self, from: data)
        XCTAssertFalse(decoded.success)
        XCTAssertEqual(decoded.action, "delete")
    }

    // MARK: - parseReminderPriority

    func testParseReminderPriorityHigh() {
        XCTAssertEqual(parseReminderPriority("high"), 1)
    }

    func testParseReminderPriorityMedium() {
        XCTAssertEqual(parseReminderPriority("medium"), 5)
    }

    func testParseReminderPriorityLow() {
        XCTAssertEqual(parseReminderPriority("low"), 9)
    }

    func testParseReminderPriorityNone() {
        XCTAssertEqual(parseReminderPriority("none"), 0)
    }

    func testParseReminderPriorityNumericHigh() {
        XCTAssertEqual(parseReminderPriority("1"), 1)
    }

    func testParseReminderPriorityNumericMedium() {
        XCTAssertEqual(parseReminderPriority("5"), 5)
    }

    func testParseReminderPriorityNumericLow() {
        XCTAssertEqual(parseReminderPriority("9"), 9)
    }

    func testParseReminderPriorityNumericNone() {
        XCTAssertEqual(parseReminderPriority("0"), 0)
    }

    func testParseReminderPriorityInvalid() {
        XCTAssertNil(parseReminderPriority("urgent"))
        XCTAssertNil(parseReminderPriority(""))
        XCTAssertNil(parseReminderPriority("3"))
        XCTAssertNil(parseReminderPriority("10"))
    }

    func testParseReminderPriorityCaseInsensitive() {
        XCTAssertEqual(parseReminderPriority("HIGH"), 1)
        XCTAssertEqual(parseReminderPriority("Medium"), 5)
        XCTAssertEqual(parseReminderPriority("LOW"), 9)
        XCTAssertEqual(parseReminderPriority("None"), 0)
    }

    // MARK: - formatReminderPriority

    func testFormatReminderPriorityHigh() {
        XCTAssertEqual(formatReminderPriority(1), "high")
    }

    func testFormatReminderPriorityMedium() {
        XCTAssertEqual(formatReminderPriority(5), "medium")
    }

    func testFormatReminderPriorityLow() {
        XCTAssertEqual(formatReminderPriority(9), "low")
    }

    func testFormatReminderPriorityNone() {
        XCTAssertEqual(formatReminderPriority(0), "none")
    }

    func testFormatReminderPriorityUnknown() {
        XCTAssertEqual(formatReminderPriority(3), "none")
        XCTAssertEqual(formatReminderPriority(99), "none")
    }

    // MARK: - EventKit access (skip if not granted)

    func testListReminderListsRequiresAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        try XCTSkipUnless(
            status == .fullAccess || status.rawValue == 3,
            "Reminders access not granted — skipping EventKit tests"
        )
        let bridge = RemindersBridge()
        let lists = try await bridge.listReminderLists()
        XCTAssertFalse(lists.isEmpty, "Expected at least one reminder list")
    }

    func testListRemindersRequiresAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        try XCTSkipUnless(
            status == .fullAccess || status.rawValue == 3,
            "Reminders access not granted — skipping EventKit tests"
        )
        let bridge = RemindersBridge()
        // Should not throw
        _ = try await bridge.listReminders(completed: false, limit: 10)
    }
}
