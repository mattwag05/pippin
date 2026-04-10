@testable import PippinLib
import XCTest

final class StatusCommandTests: XCTestCase {
    // MARK: - StatusReport Codable

    func testStatusReportEncodesMinimal() throws {
        let report = StatusReport(
            version: "0.15.0",
            mail: nil,
            calendar: nil,
            reminders: nil,
            memos: nil,
            notes: nil,
            contacts: nil,
            permissions: []
        )
        let data = try JSONEncoder().encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"version\":\"0.15.0\""))
        XCTAssertTrue(json.contains("\"permissions\":[]"))
    }

    func testStatusReportEncodesFullPayload() throws {
        let report = StatusReport(
            version: "0.15.0",
            mail: StatusReport.MailStatus(accounts: [
                StatusReport.MailAccountSummary(name: "iCloud", email: "test@icloud.com", mailboxCount: 5),
            ]),
            calendar: StatusReport.CalendarStatus(calendarCount: 3, eventsToday: 2, eventsRemaining: 1),
            reminders: StatusReport.RemindersStatus(listCount: 4, incomplete: 10, overdueCount: 2),
            memos: StatusReport.MemosStatus(recordingCount: 7),
            notes: StatusReport.NotesStatus(noteCount: 50, folderCount: 3),
            contacts: StatusReport.ContactsStatus(contactCount: 200),
            permissions: [
                StatusReport.PermissionEntry(name: "Mail", granted: true),
                StatusReport.PermissionEntry(name: "Calendar", granted: false),
            ]
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(StatusReport.self, from: data)

        XCTAssertEqual(decoded.version, "0.15.0")
        XCTAssertEqual(decoded.mail?.accounts.count, 1)
        XCTAssertEqual(decoded.mail?.accounts.first?.name, "iCloud")
        XCTAssertEqual(decoded.mail?.accounts.first?.email, "test@icloud.com")
        XCTAssertEqual(decoded.mail?.accounts.first?.mailboxCount, 5)
        XCTAssertEqual(decoded.calendar?.calendarCount, 3)
        XCTAssertEqual(decoded.calendar?.eventsToday, 2)
        XCTAssertEqual(decoded.calendar?.eventsRemaining, 1)
        XCTAssertEqual(decoded.reminders?.listCount, 4)
        XCTAssertEqual(decoded.reminders?.incomplete, 10)
        XCTAssertEqual(decoded.reminders?.overdueCount, 2)
        XCTAssertEqual(decoded.memos?.recordingCount, 7)
        XCTAssertEqual(decoded.notes?.noteCount, 50)
        XCTAssertEqual(decoded.notes?.folderCount, 3)
        XCTAssertEqual(decoded.contacts?.contactCount, 200)
        XCTAssertEqual(decoded.permissions.count, 2)
        XCTAssertTrue(decoded.permissions[0].granted)
        XCTAssertFalse(decoded.permissions[1].granted)
    }

    func testStatusReportRoundTripsNilSections() throws {
        let report = StatusReport(
            version: "0.15.0",
            mail: StatusReport.MailStatus(accounts: []),
            calendar: nil,
            reminders: nil,
            memos: nil,
            notes: nil,
            contacts: nil,
            permissions: [StatusReport.PermissionEntry(name: "Mail", granted: true)]
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(StatusReport.self, from: data)
        XCTAssertNotNil(decoded.mail)
        XCTAssertEqual(decoded.mail?.accounts.count, 0)
        XCTAssertNil(decoded.calendar)
        XCTAssertNil(decoded.reminders)
        XCTAssertNil(decoded.memos)
        XCTAssertNil(decoded.notes)
        XCTAssertNil(decoded.contacts)
    }

    // MARK: - Command Configuration

    func testStatusCommandConfiguration() {
        XCTAssertEqual(StatusCommand.configuration.commandName, "status")
        XCTAssertFalse(StatusCommand.configuration.abstract.isEmpty)
    }

    func testStatusCommandParsesNoArgs() throws {
        let command = try StatusCommand.parse([])
        XCTAssertEqual(command.output.format, .text)
    }

    func testStatusCommandParsesAgentFormat() throws {
        let command = try StatusCommand.parse(["--format", "agent"])
        XCTAssertTrue(command.output.isAgent)
    }

    func testStatusCommandParsesJSONFormat() throws {
        let command = try StatusCommand.parse(["--format", "json"])
        XCTAssertTrue(command.output.isJSON)
    }
}
