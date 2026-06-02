@testable import PippinLib
import XCTest

final class DigestTests: XCTestCase {
    // MARK: - DigestCommand parsing

    func testDigestCommandName() {
        XCTAssertEqual(DigestCommand.configuration.commandName, "digest")
    }

    func testDigestNoArgsPasses() {
        XCTAssertNoThrow(try DigestCommand.parse([]))
    }

    func testDigestDefaultMailLimit() throws {
        let cmd = try DigestCommand.parse([])
        XCTAssertEqual(cmd.mailLimit, 5)
    }

    func testDigestDefaultNotesLimit() throws {
        let cmd = try DigestCommand.parse([])
        XCTAssertEqual(cmd.notesLimit, 5)
    }

    func testDigestDefaultCalendarDays() throws {
        let cmd = try DigestCommand.parse([])
        XCTAssertEqual(cmd.calendarDays, 7)
    }

    func testDigestDefaultSkipEmpty() throws {
        let cmd = try DigestCommand.parse([])
        XCTAssertTrue(cmd.skip.isEmpty)
    }

    func testDigestCustomLimitsPasses() throws {
        let cmd = try DigestCommand.parse([
            "--mail-limit", "10",
            "--notes-limit", "3",
            "--calendar-days", "14",
        ])
        XCTAssertEqual(cmd.mailLimit, 10)
        XCTAssertEqual(cmd.notesLimit, 3)
        XCTAssertEqual(cmd.calendarDays, 14)
    }

    func testDigestZeroMailLimitFails() {
        XCTAssertThrowsError(try DigestCommand.parse(["--mail-limit", "0"]))
    }

    func testDigestZeroNotesLimitFails() {
        XCTAssertThrowsError(try DigestCommand.parse(["--notes-limit", "0"]))
    }

    func testDigestZeroCalendarDaysFails() {
        XCTAssertThrowsError(try DigestCommand.parse(["--calendar-days", "0"]))
    }

    func testDigestSkipMailPasses() throws {
        let cmd = try DigestCommand.parse(["--skip", "mail"])
        XCTAssertEqual(cmd.skip, ["mail"])
    }

    func testDigestSkipMultipleSectionsPasses() throws {
        let cmd = try DigestCommand.parse(["--skip", "mail", "notes"])
        XCTAssertEqual(cmd.skip, ["mail", "notes"])
    }

    func testDigestSkipUnknownSectionFails() {
        XCTAssertThrowsError(try DigestCommand.parse(["--skip", "contacts"]))
    }

    func testDigestAgentFormatPasses() {
        XCTAssertNoThrow(try DigestCommand.parse(["--format", "agent"]))
    }

    func testDigestJsonFormatPasses() {
        XCTAssertNoThrow(try DigestCommand.parse(["--format", "json"]))
    }

    // MARK: - DigestPayload model round-trip

    func testDigestPayloadRoundTrip() throws {
        let msg = MailMessage(
            id: "acc||INBOX||1",
            account: "test@example.com",
            mailbox: "INBOX",
            subject: "Hello",
            from: "sender@example.com",
            to: ["test@example.com"],
            date: "2026-04-20T09:00:00Z",
            read: false
        )
        let event = CalendarEvent(
            id: "event-1",
            calendarId: "cal-1",
            calendarTitle: "Work",
            title: "Standup",
            startDate: "2026-04-20T09:00:00Z",
            endDate: "2026-04-20T09:30:00Z",
            isAllDay: false
        )
        let reminder = ReminderItem(
            id: "rem-1",
            listId: "list-1",
            listTitle: "Reminders",
            title: "Call dentist",
            dueDate: "2026-04-20T09:00:00Z",
            priority: 1
        )
        let note = NoteDigestInfo(
            id: "note-1",
            title: "Meeting notes",
            folder: "Work",
            modificationDate: "2026-04-20T08:00:00Z",
            plainText: "Some content"
        )

        let payload = DigestPayload(
            generatedAt: "2026-04-20T10:00:00Z",
            mail: DigestPayload.MailSection(
                totalUnread: 1,
                perAccount: [DigestPayload.AccountSummary(
                    account: "test@example.com",
                    unread: 1,
                    topMessages: [msg]
                )]
            ),
            calendar: DigestPayload.CalendarSection(today: [event], upcoming: []),
            reminders: DigestPayload.RemindersSection(dueToday: [reminder], overdue: []),
            notes: DigestPayload.NotesSection(recent: [note]),
            warnings: []
        )

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DigestPayload.self, from: data)

        XCTAssertEqual(decoded.generatedAt, "2026-04-20T10:00:00Z")
        XCTAssertEqual(decoded.mail.totalUnread, 1)
        XCTAssertEqual(decoded.mail.perAccount.count, 1)
        XCTAssertEqual(decoded.mail.perAccount[0].account, "test@example.com")
        XCTAssertEqual(decoded.mail.perAccount[0].topMessages.count, 1)
        XCTAssertEqual(decoded.mail.perAccount[0].topMessages[0].subject, "Hello")
        XCTAssertEqual(decoded.calendar.today.count, 1)
        XCTAssertEqual(decoded.calendar.today[0].title, "Standup")
        XCTAssertTrue(decoded.calendar.upcoming.isEmpty)
        XCTAssertEqual(decoded.reminders.dueToday.count, 1)
        XCTAssertEqual(decoded.reminders.dueToday[0].title, "Call dentist")
        XCTAssertTrue(decoded.reminders.overdue.isEmpty)
        XCTAssertEqual(decoded.notes.recent.count, 1)
        XCTAssertEqual(decoded.notes.recent[0].title, "Meeting notes")
        XCTAssertTrue(decoded.warnings.isEmpty)
    }

    func testDigestPayloadEmptySections() throws {
        let payload = DigestPayload(
            generatedAt: "2026-04-20T10:00:00Z",
            mail: DigestPayload.MailSection(totalUnread: 0, perAccount: []),
            calendar: DigestPayload.CalendarSection(today: [], upcoming: []),
            reminders: DigestPayload.RemindersSection(dueToday: [], overdue: []),
            notes: DigestPayload.NotesSection(recent: []),
            warnings: ["notes: timed out"]
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DigestPayload.self, from: data)
        XCTAssertEqual(decoded.mail.totalUnread, 0)
        XCTAssertEqual(decoded.warnings.count, 1)
        XCTAssertEqual(decoded.warnings[0], "notes: timed out")
    }

    func testDigestPayloadIsSendable() {
        let payload = DigestPayload(
            generatedAt: "2026-04-20T10:00:00Z",
            mail: DigestPayload.MailSection(totalUnread: 0, perAccount: []),
            calendar: DigestPayload.CalendarSection(today: [], upcoming: []),
            reminders: DigestPayload.RemindersSection(dueToday: [], overdue: []),
            notes: DigestPayload.NotesSection(recent: []),
            warnings: []
        )
        let _: any Sendable = payload
    }

    // MARK: - NoteDigestInfo

    func testNoteDigestInfoFromNoteInfo() {
        let note = NoteInfo(
            id: "x-coredata://abc/123",
            title: "My Note",
            body: "<html>...</html>",
            plainText: "The content",
            folder: "Work",
            folderId: "folder-1",
            account: "iCloud",
            creationDate: "2026-04-01T10:00:00Z",
            modificationDate: "2026-04-20T08:00:00Z"
        )
        let digest = NoteDigestInfo(from: note)
        XCTAssertEqual(digest.id, note.id)
        XCTAssertEqual(digest.title, "My Note")
        XCTAssertEqual(digest.folder, "Work")
        XCTAssertEqual(digest.modificationDate, "2026-04-20T08:00:00Z")
        XCTAssertEqual(digest.plainText, "The content")
    }

    // MARK: - MCP tool registry: digest present and argv ends with --format agent

    func testDigestToolExistsInRegistry() {
        let tool = MCPToolRegistry.tool(named: "digest")
        XCTAssertNotNil(tool, "Expected 'digest' tool in MCPToolRegistry")
    }

    func testDigestToolArgvContainsFormatAgent() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "digest"))
        let argv = try tool.buildArgs(nil)
        XCTAssertTrue(argv.contains("--format"))
        XCTAssertTrue(argv.contains("agent"))
    }

    func testDigestToolArgvWithOptions() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "digest"))
        let args = JSONValue.object([
            "mailLimit": .int(10),
            "notesLimit": .int(3),
            "calendarDays": .int(14),
        ])
        let argv = try tool.buildArgs(args)
        XCTAssertTrue(argv.contains("--mail-limit=10"))
        XCTAssertTrue(argv.contains("--notes-limit=3"))
        XCTAssertTrue(argv.contains("--calendar-days=14"))
        XCTAssertTrue(argv.contains("--format"))
        XCTAssertTrue(argv.contains("agent"))
    }

    // MARK: - Upcoming calendar window (pippin-921)

    //
    // Regression: the upcoming window was anchored to start-of-today
    // (`startOfDay + calendarDays`), which covered only `calendarDays - 1` full
    // days beyond today — a 7-day request dropped the 7th day's events.

    func testUpcomingWindowSpansCalendarDaysBeyondToday() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000))
        let endOfToday = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: start))
        let upcomingEnd = try XCTUnwrap(DigestCommand.upcomingWindowEnd(endOfToday: endOfToday, calendarDays: 7, calendar: cal))
        let days = cal.dateComponents([.day], from: endOfToday, to: upcomingEnd).day
        XCTAssertEqual(days, 7, "the upcoming window must span calendarDays full days beyond today (not 6)")
        let expected = try XCTUnwrap(cal.date(byAdding: .day, value: 7, to: endOfToday))
        XCTAssertEqual(upcomingEnd, expected)
    }

    func testDigestRejectsCalendarDaysAboveCap() {
        XCTAssertThrowsError(try DigestCommand.parse(["--calendar-days", "367"]))
        XCTAssertThrowsError(try DigestCommand.parse(["--calendar-days", "999999999"]),
                             "an unbounded value would overflow-trap the date math")
    }

    func testDigestAcceptsCalendarDaysAtCap() {
        XCTAssertNoThrow(try DigestCommand.parse(["--calendar-days", "366"]))
    }
}
