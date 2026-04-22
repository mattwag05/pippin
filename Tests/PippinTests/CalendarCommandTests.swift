@testable import PippinLib
import XCTest

/// Tests for ArgumentParser `validate()` logic in CalendarCommand subcommands.
final class CalendarCommandTests: XCTestCase {
    // MARK: - Create: required flags

    func testCreateMissingTitleFails() {
        // --title is required (no default value)
        XCTAssertThrowsError(try CalendarCommand.Create.parse(["--start", "2026-03-07"]))
    }

    func testCreateMissingStartFails() {
        // --start is required
        XCTAssertThrowsError(try CalendarCommand.Create.parse(["--title", "Meeting"]))
    }

    func testCreateInvalidStartFails() {
        XCTAssertThrowsError(try CalendarCommand.Create.parse([
            "--title", "Test", "--start", "not-a-date",
        ]))
    }

    func testCreateInvalidEndFails() {
        XCTAssertThrowsError(try CalendarCommand.Create.parse([
            "--title", "Test", "--start", "2026-03-07T10:00:00", "--end", "invalid",
        ]))
    }

    func testCreateValidMinimalPasses() {
        XCTAssertNoThrow(try CalendarCommand.Create.parse([
            "--title", "Test", "--start", "2026-03-07",
        ]))
    }

    func testCreateValidISOStartPasses() {
        XCTAssertNoThrow(try CalendarCommand.Create.parse([
            "--title", "Meeting", "--start", "2026-03-07T10:00:00",
        ]))
    }

    func testCreateValidISOWithEndPasses() {
        XCTAssertNoThrow(try CalendarCommand.Create.parse([
            "--title", "Meeting",
            "--start", "2026-03-07T10:00:00",
            "--end", "2026-03-07T11:00:00",
        ]))
    }

    func testCreateAllDayFlagSetsToTrue() throws {
        let cmd = try CalendarCommand.Create.parse([
            "--title", "Holiday", "--start", "2026-03-07", "--all-day",
        ])
        XCTAssertTrue(cmd.allDay)
    }

    func testCreateDefaultsAllDayFalse() throws {
        let cmd = try CalendarCommand.Create.parse([
            "--title", "Meeting", "--start", "2026-03-07",
        ])
        XCTAssertFalse(cmd.allDay)
    }

    func testCreateAcceptsOptionalFields() {
        XCTAssertNoThrow(try CalendarCommand.Create.parse([
            "--title", "Meeting",
            "--start", "2026-03-07T10:00:00",
            "--end", "2026-03-07T11:00:00",
            "--location", "Room A",
            "--notes", "Bring notes",
            "--url", "https://example.com",
            "--format", "json",
        ]))
    }

    // MARK: - Delete: --force required

    func testDeleteWithoutForceFails() {
        XCTAssertThrowsError(try CalendarCommand.Delete.parse(["some-event-id"]))
    }

    func testDeleteWithForcePasses() {
        XCTAssertNoThrow(try CalendarCommand.Delete.parse(["some-event-id", "--force"]))
    }

    func testDeleteWithForceAndJsonFormat() {
        XCTAssertNoThrow(try CalendarCommand.Delete.parse([
            "some-event-id", "--force", "--format", "json",
        ]))
    }

    // MARK: - Events: date validation

    func testEventsInvalidFromFails() {
        XCTAssertThrowsError(try CalendarCommand.Events.parse(["--from", "not-a-date"]))
    }

    func testEventsInvalidToFails() {
        XCTAssertThrowsError(try CalendarCommand.Events.parse(["--to", "not-a-date"]))
    }

    func testEventsValidFromToPasses() {
        XCTAssertNoThrow(try CalendarCommand.Events.parse([
            "--from", "2026-03-07", "--to", "2026-03-08",
        ]))
    }

    func testEventsValidISOFromTo() {
        XCTAssertNoThrow(try CalendarCommand.Events.parse([
            "--from", "2026-03-07T00:00:00", "--to", "2026-03-07T23:59:59",
        ]))
    }

    func testEventsDefaultLimit() throws {
        let cmd = try CalendarCommand.Events.parse([])
        XCTAssertEqual(cmd.limit, 50)
    }

    func testEventsCustomLimit() throws {
        let cmd = try CalendarCommand.Events.parse(["--limit", "10"])
        XCTAssertEqual(cmd.limit, 10)
    }

    func testEventsZeroLimitFails() {
        XCTAssertThrowsError(try CalendarCommand.Events.parse(["--limit", "0"]))
    }

    func testEventsNoArgsUsesDefaults() {
        XCTAssertNoThrow(try CalendarCommand.Events.parse([]))
    }

    // MARK: - Events pagination flags (pippin-gb3)

    func testEventsParsesPageSize() throws {
        let cmd = try CalendarCommand.Events.parse(["--page-size", "8"])
        XCTAssertEqual(cmd.pagination.pageSize, 8)
        XCTAssertTrue(cmd.pagination.isActive)
    }

    func testEventsParsesCursor() throws {
        let token = try Pagination.encode(Cursor(offset: 16, filterHash: "abcd1234"))
        let cmd = try CalendarCommand.Events.parse(["--cursor", token])
        XCTAssertEqual(cmd.pagination.cursor, token)
    }

    func testEventsPaginationInactiveByDefault() throws {
        let cmd = try CalendarCommand.Events.parse([])
        XCTAssertFalse(cmd.pagination.isActive)
    }

    // MARK: - Upcoming pagination flags (pippin-a9m)

    func testUpcomingParsesPageSize() throws {
        let cmd = try CalendarCommand.Upcoming.parse(["--page-size", "9"])
        XCTAssertEqual(cmd.pagination.pageSize, 9)
        XCTAssertTrue(cmd.pagination.isActive)
    }

    func testUpcomingParsesCursor() throws {
        let token = try Pagination.encode(Cursor(offset: 9, filterHash: "upcoming-hash"))
        let cmd = try CalendarCommand.Upcoming.parse(["--cursor", token])
        XCTAssertEqual(cmd.pagination.cursor, token)
    }

    func testUpcomingPaginationInactiveByDefault() throws {
        let cmd = try CalendarCommand.Upcoming.parse([])
        XCTAssertFalse(cmd.pagination.isActive)
    }

    func testUpcomingLimitZeroFails() {
        XCTAssertThrowsError(try CalendarCommand.Upcoming.parse(["--limit", "0"]))
    }

    // MARK: - Edit: argument validation

    func testEditRequiresId() {
        XCTAssertThrowsError(try CalendarCommand.Edit.parse([]))
    }

    func testEditIdOnlyPasses() {
        XCTAssertNoThrow(try CalendarCommand.Edit.parse(["event-id"]))
    }

    func testEditInvalidStartFails() {
        XCTAssertThrowsError(try CalendarCommand.Edit.parse(["event-id", "--start", "bad-date"]))
    }

    func testEditInvalidEndFails() {
        XCTAssertThrowsError(try CalendarCommand.Edit.parse(["event-id", "--end", "bad-date"]))
    }

    func testEditValidFieldsPasses() {
        XCTAssertNoThrow(try CalendarCommand.Edit.parse([
            "event-id",
            "--title", "Updated",
            "--start", "2026-03-07T10:00:00",
            "--end", "2026-03-07T11:00:00",
        ]))
    }

    // MARK: - Agenda: days validation

    func testAgendaZeroDaysFails() {
        XCTAssertThrowsError(try CalendarCommand.Agenda.parse(["--days", "0"]))
    }

    func testAgendaEightDaysFails() {
        XCTAssertThrowsError(try CalendarCommand.Agenda.parse(["--days", "8"]))
    }

    func testAgendaSevenDaysPasses() {
        XCTAssertNoThrow(try CalendarCommand.Agenda.parse(["--days", "7"]))
    }

    func testAgendaOneDayPasses() {
        XCTAssertNoThrow(try CalendarCommand.Agenda.parse(["--days", "1"]))
    }

    func testAgendaDefaultDays() throws {
        let cmd = try CalendarCommand.Agenda.parse([])
        XCTAssertEqual(cmd.days, 1)
    }

    func testAgendaNoArgsPasses() {
        XCTAssertNoThrow(try CalendarCommand.Agenda.parse([]))
    }

    // MARK: - Output format

    func testEventsAcceptsJsonFormat() {
        XCTAssertNoThrow(try CalendarCommand.Events.parse(["--format", "json"]))
    }

    func testListAcceptsJsonFormat() {
        XCTAssertNoThrow(try CalendarCommand.ListCalendars.parse(["--format", "json"]))
    }

    func testShowRequiresId() {
        XCTAssertThrowsError(try CalendarCommand.Show.parse([]))
    }

    func testShowWithIdPasses() {
        XCTAssertNoThrow(try CalendarCommand.Show.parse(["some-event-id"]))
    }

    func testShowAcceptsJsonFormat() {
        XCTAssertNoThrow(try CalendarCommand.Show.parse(["event-id", "--format", "json"]))
    }

    func testAgendaAcceptsJsonFormat() {
        XCTAssertNoThrow(try CalendarCommand.Agenda.parse(["--format", "json"]))
    }

    // MARK: - Edit: --span flag

    func testEditSpanDefaultThis() throws {
        let cmd = try CalendarCommand.Edit.parse(["event-id"])
        XCTAssertEqual(cmd.span, "this")
    }

    func testEditSpanFuturePasses() {
        XCTAssertNoThrow(try CalendarCommand.Edit.parse(["event-id", "--span", "future"]))
    }

    func testEditSpanInvalidFails() {
        XCTAssertThrowsError(try CalendarCommand.Edit.parse(["event-id", "--span", "all"]))
    }

    // MARK: - Delete: --span flag

    func testDeleteSpanDefaultThis() throws {
        let cmd = try CalendarCommand.Delete.parse(["event-id", "--force"])
        XCTAssertEqual(cmd.span, "this")
    }

    func testDeleteSpanFuturePasses() {
        XCTAssertNoThrow(try CalendarCommand.Delete.parse(["event-id", "--force", "--span", "future"]))
    }

    // MARK: - Create: --alert flag

    func testCreateAlertValidPasses() {
        XCTAssertNoThrow(try CalendarCommand.Create.parse([
            "--title", "Meeting", "--start", "2026-03-07", "--alert", "15m",
        ]))
    }

    func testCreateAlertHoursPasses() {
        XCTAssertNoThrow(try CalendarCommand.Create.parse([
            "--title", "Meeting", "--start", "2026-03-07", "--alert", "1h",
        ]))
    }

    func testCreateAlertInvalidFails() {
        XCTAssertThrowsError(try CalendarCommand.Create.parse([
            "--title", "Meeting", "--start", "2026-03-07", "--alert", "15x",
        ]))
    }

    // MARK: - Edit: --alert flag

    func testEditAlertValidPasses() {
        XCTAssertNoThrow(try CalendarCommand.Edit.parse(["event-id", "--alert", "1h"]))
    }

    func testEditAlertInvalidFails() {
        XCTAssertThrowsError(try CalendarCommand.Edit.parse(["event-id", "--alert", "bad"]))
    }

    // MARK: - Edit: --all-day / --no-all-day

    func testEditAllDayFlagPasses() throws {
        let cmd = try CalendarCommand.Edit.parse(["event-id", "--all-day"])
        XCTAssertTrue(cmd.allDay)
        XCTAssertFalse(cmd.noAllDay)
    }

    func testEditNoAllDayFlagPasses() throws {
        let cmd = try CalendarCommand.Edit.parse(["event-id", "--no-all-day"])
        XCTAssertFalse(cmd.allDay)
        XCTAssertTrue(cmd.noAllDay)
    }

    func testEditAllDayAndNoAllDayFails() {
        XCTAssertThrowsError(try CalendarCommand.Edit.parse(["event-id", "--all-day", "--no-all-day"]))
    }

    func testEditNoAllDayFlagsDefaultFalse() throws {
        let cmd = try CalendarCommand.Edit.parse(["event-id"])
        XCTAssertFalse(cmd.allDay)
        XCTAssertFalse(cmd.noAllDay)
    }

    // MARK: - Events: --calendar-name

    func testEventsCalendarNamePasses() {
        XCTAssertNoThrow(try CalendarCommand.Events.parse(["--calendar-name", "Personal"]))
    }

    func testEventsCalendarAndCalendarNameFails() {
        XCTAssertThrowsError(try CalendarCommand.Events.parse([
            "--calendar", "cal-id", "--calendar-name", "Personal",
        ]))
    }

    // MARK: - Search subcommand

    func testSearchRequiresQuery() {
        XCTAssertThrowsError(try CalendarCommand.Search.parse([]))
    }

    func testSearchValidQueryPasses() {
        XCTAssertNoThrow(try CalendarCommand.Search.parse(["--query", "meeting"]))
    }

    func testSearchInvalidFromFails() {
        XCTAssertThrowsError(try CalendarCommand.Search.parse(["--query", "x", "--from", "bad-date"]))
    }

    func testSearchInvalidToFails() {
        XCTAssertThrowsError(try CalendarCommand.Search.parse(["--query", "x", "--to", "bad-date"]))
    }

    func testSearchZeroLimitFails() {
        XCTAssertThrowsError(try CalendarCommand.Search.parse(["--query", "x", "--limit", "0"]))
    }

    func testSearchDefaultLimit() throws {
        let cmd = try CalendarCommand.Search.parse(["--query", "x"])
        XCTAssertEqual(cmd.limit, 50)
    }

    func testSearchWithCalendarName() {
        XCTAssertNoThrow(try CalendarCommand.Search.parse(["--query", "meeting", "--calendar-name", "Work"]))
    }

    func testSearchJsonFormat() {
        XCTAssertNoThrow(try CalendarCommand.Search.parse(["--query", "x", "--format", "json"]))
    }

    func testSearchValidRangesPasses() {
        XCTAssertNoThrow(try CalendarCommand.Search.parse([
            "--query", "standup",
            "--from", "2026-01-01",
            "--to", "2026-12-31",
        ]))
    }

    // MARK: - Today subcommand

    func testTodayCommandName() {
        XCTAssertEqual(CalendarCommand.Today.configuration.commandName, "today")
    }

    func testTodayNoArgsPasses() {
        XCTAssertNoThrow(try CalendarCommand.Today.parse([]))
    }

    func testTodayJsonFormatPasses() {
        XCTAssertNoThrow(try CalendarCommand.Today.parse(["--format", "json"]))
    }

    func testTodayAgentFormatPasses() {
        XCTAssertNoThrow(try CalendarCommand.Today.parse(["--format", "agent"]))
    }

    func testTodayFieldsOptionPasses() throws {
        let cmd = try CalendarCommand.Today.parse(["--fields", "title,startDate"])
        XCTAssertEqual(cmd.fields, "title,startDate")
    }

    // MARK: - Remaining subcommand

    func testRemainingCommandName() {
        XCTAssertEqual(CalendarCommand.Remaining.configuration.commandName, "remaining")
    }

    func testRemainingNoArgsPasses() {
        XCTAssertNoThrow(try CalendarCommand.Remaining.parse([]))
    }

    func testRemainingJsonFormatPasses() {
        XCTAssertNoThrow(try CalendarCommand.Remaining.parse(["--format", "json"]))
    }

    func testRemainingAgentFormatPasses() {
        XCTAssertNoThrow(try CalendarCommand.Remaining.parse(["--format", "agent"]))
    }

    func testRemainingFieldsOptionPasses() throws {
        let cmd = try CalendarCommand.Remaining.parse(["--fields", "title,endDate"])
        XCTAssertEqual(cmd.fields, "title,endDate")
    }

    // MARK: - Upcoming subcommand

    func testUpcomingCommandName() {
        XCTAssertEqual(CalendarCommand.Upcoming.configuration.commandName, "upcoming")
    }

    func testUpcomingNoArgsPasses() {
        XCTAssertNoThrow(try CalendarCommand.Upcoming.parse([]))
    }

    func testUpcomingJsonFormatPasses() {
        XCTAssertNoThrow(try CalendarCommand.Upcoming.parse(["--format", "json"]))
    }

    func testUpcomingAgentFormatPasses() {
        XCTAssertNoThrow(try CalendarCommand.Upcoming.parse(["--format", "agent"]))
    }

    func testUpcomingFieldsOptionPasses() throws {
        let cmd = try CalendarCommand.Upcoming.parse(["--fields", "id,title,startDate"])
        XCTAssertEqual(cmd.fields, "id,title,startDate")
    }

    // MARK: - Conflicts subcommand

    func testConflictsCommandName() {
        XCTAssertEqual(CalendarCommand.Conflicts.configuration.commandName, "conflicts")
    }

    func testConflictsNoArgsPasses() {
        XCTAssertNoThrow(try CalendarCommand.Conflicts.parse([]))
    }

    func testConflictsValidFromToPasses() {
        XCTAssertNoThrow(try CalendarCommand.Conflicts.parse([
            "--from", "2026-03-07", "--to", "2026-03-08",
        ]))
    }

    func testConflictsInvalidFromFails() {
        XCTAssertThrowsError(try CalendarCommand.Conflicts.parse(["--from", "not-a-date"]))
    }

    func testConflictsInvalidToFails() {
        XCTAssertThrowsError(try CalendarCommand.Conflicts.parse(["--to", "not-a-date"]))
    }

    func testConflictsValidRangePasses() {
        XCTAssertNoThrow(try CalendarCommand.Conflicts.parse(["--range", "today"]))
    }

    func testConflictsInvalidRangeFails() {
        XCTAssertThrowsError(try CalendarCommand.Conflicts.parse(["--range", "yesterday"]))
    }

    func testConflictsJsonFormatPasses() {
        XCTAssertNoThrow(try CalendarCommand.Conflicts.parse(["--format", "json"]))
    }

    func testConflictsAgentFormatPasses() {
        XCTAssertNoThrow(try CalendarCommand.Conflicts.parse(["--format", "agent"]))
    }

    func testConflictsRangeWeekPasses() {
        XCTAssertNoThrow(try CalendarCommand.Conflicts.parse(["--range", "week"]))
    }

    func testConflictsRangeMonthPasses() {
        XCTAssertNoThrow(try CalendarCommand.Conflicts.parse(["--range", "month"]))
    }

    func testConflictsRangeTodayPlusPasses() {
        XCTAssertNoThrow(try CalendarCommand.Conflicts.parse(["--range", "today+3"]))
    }

    // MARK: - SmartCreate --allow-conflicts flag

    func testSmartCreateAllowConflictsDefaultFalse() throws {
        let cmd = try CalendarCommand.SmartCreate.parse(["coffee with Alice tomorrow at 3pm"])
        XCTAssertFalse(cmd.allowConflicts)
    }

    func testSmartCreateAllowConflictsFlagPasses() throws {
        let cmd = try CalendarCommand.SmartCreate.parse([
            "coffee with Alice tomorrow at 3pm", "--allow-conflicts",
        ])
        XCTAssertTrue(cmd.allowConflicts)
    }

    func testSmartCreateIsInCalendarSubcommands() {
        let names = CalendarCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("conflicts"))
        XCTAssertTrue(names.contains("smart-create"))
    }
}
