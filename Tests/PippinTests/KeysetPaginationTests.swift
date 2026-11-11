@testable import PippinLib
import XCTest

/// In-memory keyset paging (pippin-hzuw): rows arriving or leaving between two
/// page fetches must not make page 2 repeat or skip a row. Synthetic rows only.
final class KeysetPaginationTests: XCTestCase {
    private func options(_ cursor: String?) -> PaginationOptions {
        var opts = PaginationOptions()
        opts.cursor = cursor
        return opts
    }

    private func token(_ page: Page<some Encodable & Sendable>) throws -> String {
        try XCTUnwrap(page.nextCursor)
    }

    private func reminder(_ id: String, due: String? = nil, created: String = "2026-01-01T00:00:00Z") -> ReminderItem {
        ReminderItem(
            id: id, listId: "l", listTitle: "L", title: id, dueDate: due, creationDate: created
        )
    }

    // MARK: reminders

    func testRemindersPageSurvivesEarlierReminderAddedBetweenPages() throws {
        var rows = [
            reminder("a", due: "2026-03-01"), reminder("b", due: "2026-03-02"),
            reminder("c", due: "2026-03-03"), reminder("n", created: "2026-01-02T00:00:00Z"),
        ]
        let page1 = try RemindersCommand.List.keysetPage(
            rows, pagination: options(nil), offset: 0, pageSize: 2, filterHash: "h"
        )
        XCTAssertEqual(page1.items.map(\.id), ["a", "b"])
        let cursor = try token(page1)

        rows.append(reminder("early", due: "2026-02-01")) // sorts before everything served
        let offsetPage2 = try Pagination.paginate(
            all: rows.sorted { RemindersCommand.List.pageKey($0) < RemindersCommand.List.pageKey($1) },
            offset: 2, pageSize: 2, filterHash: "h"
        )
        XCTAssertEqual(offsetPage2.items.map(\.id), ["b", "c"], "offset paging repeats b")

        let page2 = try RemindersCommand.List.keysetPage(
            rows, pagination: options(cursor), offset: 2, pageSize: 2, filterHash: "h"
        )
        XCTAssertEqual(page2.items.map(\.id), ["c", "n"])
        XCTAssertNil(page2.nextCursor)
    }

    func testRemindersPageResumesWhenAnchorRowWasDeleted() throws {
        var rows = [reminder("a", due: "2026-03-01"), reminder("b", due: "2026-03-02"), reminder("c", due: "2026-03-03")]
        let cursor = try token(RemindersCommand.List.keysetPage(
            rows, pagination: options(nil), offset: 0, pageSize: 2, filterHash: "h"
        ))
        rows.removeAll { $0.id == "b" }
        let page2 = try RemindersCommand.List.keysetPage(
            rows, pagination: options(cursor), offset: 2, pageSize: 2, filterHash: "h"
        )
        XCTAssertEqual(page2.items.map(\.id), ["c"])
    }

    // MARK: calendar

    private func event(_ id: String, _ start: String) -> CalendarEvent {
        CalendarEvent(id: id, calendarId: "c", calendarTitle: "C", title: id, startDate: start, endDate: start, isAllDay: false)
    }

    func testCalendarPageSurvivesEventAddedBetweenPagesAndKeepsRecurringOccurrences() throws {
        var events = [
            event("s", "2026-03-01T09:00:00Z"), event("s", "2026-03-02T09:00:00Z"), // one series, two occurrences
            event("x", "2026-03-03T09:00:00Z"),
        ]
        let page1 = try CalendarCommand.keysetPage(events, pagination: options(nil), offset: 0, pageSize: 2, filterHash: "h")
        XCTAssertEqual(page1.items.map(\.startDate), ["2026-03-01T09:00:00Z", "2026-03-02T09:00:00Z"])
        let cursor = try token(page1)

        events.insert(event("new", "2026-02-20T09:00:00Z"), at: 0)
        let page2 = try CalendarCommand.keysetPage(events, pagination: options(cursor), offset: 2, pageSize: 2, filterHash: "h")
        XCTAssertEqual(page2.items.map(\.id), ["x"], "offset paging would repeat the second occurrence")
    }

    // MARK: action log

    private func entry(_ id: String) -> ActionEntry {
        ActionEntry(
            id: id, ts: "2026-03-01T00:00:00Z", tool: "mail_send", args: nil, rule: nil, outcome: "ok",
            errorCode: nil, finishedAt: nil, undo: .no("test"), undone: false
        )
    }

    func testActionLogPageSurvivesNewActionBetweenPages() throws {
        var entries = ["e3", "e2", "e1"].map(entry) // newest first
        let page1 = try LogCommand.keysetPage(entries, of: entries, pagination: options(nil), offset: 0, pageSize: 2, filterHash: "h")
        XCTAssertEqual(page1.items.map(\.id), ["e3", "e2"])
        let cursor = try token(page1)

        entries.insert(entry("e4"), at: 0)
        let page2 = try LogCommand.keysetPage(entries, of: entries, pagination: options(cursor), offset: 2, pageSize: 2, filterHash: "h")
        XCTAssertEqual(page2.items.map(\.id), ["e1"], "offset paging would repeat e2")
    }

    // MARK: cursor compatibility

    func testStringAnchorRoundTripsAndLegacyCursorDecodesWithoutIt() throws {
        let anchor = Cursor.Anchor(epoch: 5, id: "abc")
        let decoded = try Pagination.decode(Pagination.encode(Cursor(offset: 1, filterHash: "h", anchor: anchor)))
        XCTAssertEqual(decoded.anchor, anchor)
        let old = try Pagination.decode(Pagination.encode(Cursor(offset: 1, filterHash: "h", anchor: Cursor.Anchor(epoch: 1, rowid: 2))))
        XCTAssertNil(old.anchor?.id)
        XCTAssertThrowsError(try Pagination.decode("garbage!"))
    }
}
