import ArgumentParser
import Foundation
@testable import PippinLib
import XCTest

/// Each undo inverse, run end to end against a fake app: the action goes
/// through the gate, the inverse through `Undo.perform`, and every argv either
/// one produced is parsed by the real CLI command it names.
final class UndoTests: XCTestCase {
    private var sandbox = SafetySandbox()

    override func setUp() {
        sandbox = SafetySandbox()
    }

    override func tearDown() {
        sandbox.remove()
    }

    /// One item in a fake app. `show` returns it; any other command applies
    /// its `--flag=value` options to the fields named in `flags`.
    private final class FakeItem: @unchecked Sendable {
        private let lock = NSLock()
        private var fields: [String: JSONValue]
        private let flags: [String: String]

        init(_ fields: [String: JSONValue], flags: [String: String]) {
            self.fields = fields
            self.flags = flags
        }

        subscript(key: String) -> JSONValue? {
            get { lock.withLock { fields[key] } }
            set { lock.withLock { fields[key] = newValue } }
        }

        var runner: FakeRunner { FakeRunner { [self] in respond($0) } }

        func respond(_ argv: [String]) -> (text: String, isError: Bool) {
            do {
                return lock.withLock {
                    let options = argv.prefix { $0 != "--" }
                    if !argv.contains("show") {
                        for (index, token) in options.enumerated() where token.hasPrefix("--") {
                            // `--flag=value`, or `--flag ""` for an empty value.
                            let equals = token.firstIndex(of: "=")
                            guard let key = flags[String(token[..<(equals ?? token.endIndex)])] else { continue }
                            let value = equals.map { String(token[token.index(after: $0)...]) } ?? Array(options)[index + 1]
                            switch key {
                            case "priority": fields[key] = .int(Int64(value) ?? 0)
                            case "emails", "phones": fields[key] = .array([.object(["label": .string("work"), "value": .string(value)])])
                            default: fields[key] = .string(value)
                            }
                        }
                        if argv.contains("complete") { fields["isCompleted"] = .bool(!argv.contains("--incomplete")) }
                    }
                    let data = argv.contains("show") ? JSONValue.object(fields) : .object(["success": .bool(true)])
                    return (ArgRedactor.canonicalJSON(.object(["v": .int(4), "status": .string("ok"), "duration_ms": .int(1), "data": data])), false)
                }
            }
        }
    }

    private static let reminderFlags = ["--title": "title", "--due": "dueDate", "--priority": "priority", "--notes": "notes", "--url": "url", "--list": "listId"]
    private static let eventFlags = ["--title": "title", "--start": "startDate", "--end": "endDate", "--calendar": "calendarId", "--location": "location", "--notes": "notes", "--url": "url"]
    private static let contactFlags = ["--first": "givenName", "--last": "familyName", "--organization": "organization", "--job-title": "jobTitle", "--email": "emails", "--phone": "phones"]
    private static let noteFlags = ["--title": "title", "--body": "body"]

    private func assertRealCommands(_ calls: [[String]], file: StaticString = #filePath, line: UInt = #line) {
        let groups: [String: ParsableCommand.Type] = [
            "mail": MailCommand.self, "reminders": RemindersCommand.self, "calendar": CalendarCommand.self,
            "contacts": ContactsCommand.self, "notes": NotesCommand.self,
        ]
        for argv in calls {
            guard let group = groups[argv[0]] else { XCTFail("unknown command \(argv)", file: file, line: line); continue }
            XCTAssertNoThrow(try group.parseAsRoot(Array(argv.dropFirst())), "\(argv)", file: file, line: line)
            XCTAssertEqual(argv.contains("--format") ? "agent" : nil, "agent", "\(argv)", file: file, line: line)
        }
    }

    /// Run `tool` through the gate and return its log entry.
    private func act(_ tool: String, _ args: JSONValue, runner: FakeRunner) async throws -> ActionEntry {
        let result = await sandbox.gate().attempt(tool, args, runner: runner)
        XCTAssertNil(result.code, "\(tool): \(result)")
        return try XCTUnwrap(ActionLog(path: sandbox.logPath).entries().first)
    }

    private func undo(_ id: String, runner: FakeRunner) async -> Result<Undo.Outcome, Error> {
        do { return try await .success(Undo.perform(id: id, stateDir: sandbox.stateDir, run: runner.run)) } catch { return .failure(error) }
    }

    private func code(_ result: Result<Undo.Outcome, Error>) -> String? {
        if case let .failure(error) = result { return agentErrorCode(for: error) }
        return nil
    }

    // MARK: - Reminders

    func testUndoRemindersCompleteUncompletes() async throws {
        let item = FakeItem(["id": .string("REMINDER-FULL-ID"), "title": .string("Call"), "isCompleted": .bool(false)], flags: Self.reminderFlags)
        let runner = item.runner
        let entry = try await act("reminders_complete", .object(["id": .string("REMINDER")]), runner: runner)
        XCTAssertEqual(item["isCompleted"], .bool(true))
        XCTAssertEqual(entry.undo, UndoInfo(supported: true, reason: nil, sidecar: "undo/\(entry.id).json"))

        let undone = await undo(entry.id, runner: runner)
        XCTAssertNil(code(undone))
        XCTAssertEqual(item["isCompleted"], .bool(false))
        XCTAssertEqual(runner.calls.last, ["reminders", "complete", "REMINDER-FULL-ID", "--incomplete", "--format", "agent"])
        assertRealCommands(runner.calls)

        // Once only, and the log says so.
        XCTAssertTrue(try XCTUnwrap(ActionLog(path: sandbox.logPath).entries().first).undone)
        let again = await undo(entry.id, runner: runner)
        XCTAssertEqual(code(again), "already_undone")
    }

    func testCompletingAnAlreadyCompletedReminderIsNotUndoable() async throws {
        let item = FakeItem(["id": .string("REMINDER-FULL-ID"), "isCompleted": .bool(true)], flags: Self.reminderFlags)
        let entry = try await act("reminders_complete", .object(["id": .string("REMINDER-FULL-ID")]), runner: item.runner)
        XCTAssertFalse(entry.undo.supported)
        XCTAssertNotNil(entry.undo.reason)
        let result = await undo(entry.id, runner: item.runner)
        XCTAssertEqual(code(result), "undo_not_supported")
    }

    func testUndoRemindersEditRestoresPriorFields() async throws {
        let item = FakeItem([
            "id": .string("REMINDER-FULL-ID"), "title": .string("Old title"), "notes": .null,
            "dueDate": .string("2026-11-10T09:00:00Z"), "priority": .int(5), "listId": .string("LIST-A"),
        ], flags: Self.reminderFlags)
        let runner = item.runner
        let entry = try await act("reminders_edit", .object([
            "id": .string("REMINDER-FULL-ID"), "title": .string("New title"), "notes": .string("new notes"),
            "due": .string("2026-12-01"), "priority": .string("1"), "list": .string("LIST-B"),
        ]), runner: runner)
        XCTAssertEqual(item["title"], .string("New title"))
        XCTAssertTrue(entry.undo.supported, entry.undo.reason ?? "")

        let undone = await undo(entry.id, runner: runner)
        XCTAssertNil(code(undone))
        XCTAssertEqual(item["title"], .string("Old title"))
        XCTAssertEqual(item["notes"], .string(""), "notes that did not exist are cleared")
        XCTAssertEqual(item["dueDate"], .string("2026-11-10T09:00:00Z"))
        XCTAssertEqual(item["priority"], .int(5))
        XCTAssertEqual(item["listId"], .string("LIST-A"))
        assertRealCommands(runner.calls)
    }

    func testAFieldPippinCannotClearMakesTheEditNotUndoable() async throws {
        let item = FakeItem(["id": .string("REMINDER-FULL-ID"), "title": .string("T"), "dueDate": .null], flags: Self.reminderFlags)
        let entry = try await act("reminders_edit", .object(["id": .string("REMINDER-FULL-ID"), "due": .string("2026-12-01")]), runner: item.runner)
        XCTAssertFalse(entry.undo.supported)
        XCTAssertTrue(entry.undo.reason?.contains("due") == true, entry.undo.reason ?? "")
    }

    func testUndoRefusesWhenTheTargetChangedSinceTheAction() async throws {
        let item = FakeItem(["id": .string("REMINDER-FULL-ID"), "title": .string("Old title")], flags: Self.reminderFlags)
        let runner = item.runner
        let entry = try await act("reminders_edit", .object(["id": .string("REMINDER-FULL-ID"), "title": .string("New title")]), runner: runner)
        item["title"] = .string("Edited by the user since")
        let before = runner.actingCalls.count
        let result = await undo(entry.id, runner: runner)
        XCTAssertEqual(code(result), "undo_target_changed")
        XCTAssertEqual(item["title"], .string("Edited by the user since"))
        XCTAssertEqual(runner.actingCalls.count, before, "the inverse must not run")
        XCTAssertFalse(try XCTUnwrap(ActionLog(path: sandbox.logPath).entries().first).undone)
    }

    // MARK: - Calendar

    func testUndoCalendarEditRestoresPriorFields() async throws {
        let item = FakeItem([
            "id": .string("EVENT-1"), "title": .string("Standup"), "location": .null, "isAllDay": .bool(false),
            "startDate": .string("2026-11-10T09:00:00Z"), "endDate": .string("2026-11-10T09:30:00Z"), "isRecurring": .bool(false),
        ], flags: Self.eventFlags)
        let runner = item.runner
        let entry = try await act("calendar_edit", .object([
            "id": .string("EVENT-1"), "title": .string("Retro"), "location": .string("Room 4"),
            "start": .string("2026-11-11T10:00:00Z"), "end": .string("2026-11-11T11:00:00Z"),
        ]), runner: runner)
        XCTAssertTrue(entry.undo.supported, entry.undo.reason ?? "")
        let undone = await undo(entry.id, runner: runner)
        XCTAssertNil(code(undone))
        XCTAssertEqual(item["title"], .string("Standup"))
        XCTAssertEqual(item["location"], .string(""))
        XCTAssertEqual(item["startDate"], .string("2026-11-10T09:00:00Z"))
        XCTAssertEqual(item["endDate"], .string("2026-11-10T09:30:00Z"))
        assertRealCommands(runner.calls)
    }

    func testRecurringAndSeriesCalendarEditsAreNotUndoable() async throws {
        let recurring = FakeItem(["id": .string("EVENT-1"), "title": .string("Standup"), "isRecurring": .bool(true)], flags: Self.eventFlags)
        var entry = try await act("calendar_edit", .object(["id": .string("EVENT-1"), "title": .string("X")]), runner: recurring.runner)
        XCTAssertEqual(entry.undo.supported, false)
        let single = FakeItem(["id": .string("EVENT-2"), "title": .string("Standup")], flags: Self.eventFlags)
        entry = try await act("calendar_edit", .object(["id": .string("EVENT-2"), "title": .string("X"), "span": .string("all")]), runner: single.runner)
        XCTAssertEqual(entry.undo.supported, false)
        XCTAssertTrue(entry.undo.reason?.contains("span") == true)
    }

    // MARK: - Contacts

    func testUndoContactsEditRestoresPriorFields() async throws {
        let item = FakeItem([
            "id": .string("CONTACT-1"), "givenName": .string("Ada"), "familyName": .string("Lovelace"), "jobTitle": .null,
            "emails": .array([.object(["label": .string("work"), "value": .string("ada@example.com")])]),
        ], flags: Self.contactFlags)
        let runner = item.runner
        let entry = try await act("contacts_edit", .object([
            "identifier": .string("CONTACT-1"), "first": .string("Augusta"), "jobTitle": .string("Countess"), "email": .string("new@example.com"),
        ]), runner: runner)
        XCTAssertTrue(entry.undo.supported, entry.undo.reason ?? "")
        let undone = await undo(entry.id, runner: runner)
        XCTAssertNil(code(undone))
        XCTAssertEqual(item["givenName"], .string("Ada"))
        XCTAssertEqual(item["jobTitle"], .string(""))
        XCTAssertEqual(item["emails"]?.arrayValue?.first?["value"], .string("ada@example.com"))
        assertRealCommands(runner.calls)
    }

    func testReplacingSeveralAddressesIsNotUndoable() async throws {
        let item = FakeItem(["id": .string("CONTACT-1"), "emails": .array([
            .object(["value": .string("a@example.com")]), .object(["value": .string("b@example.com")]),
        ])], flags: Self.contactFlags)
        let entry = try await act("contacts_edit", .object(["identifier": .string("CONTACT-1"), "email": .string("c@example.com")]), runner: item.runner)
        XCTAssertFalse(entry.undo.supported)
        XCTAssertTrue(entry.undo.reason?.contains("email") == true)
    }

    // MARK: - Notes

    func testUndoNotesEditRestoresThePriorBodyFromA0600Sidecar() async throws {
        let priorBody = "<div>Original <b>formatted</b> body, kept private</div>"
        let item = FakeItem(["id": .string("x-coredata://note/p1"), "title": .string("Plan"), "body": .string(priorBody)], flags: Self.noteFlags)
        let runner = item.runner
        let entry = try await act("notes_edit", .object(["id": .string("x-coredata://note/p1"), "body": .string("replacement text")]), runner: runner)
        XCTAssertEqual(item["body"], .string("replacement text"))
        XCTAssertTrue(entry.undo.supported, entry.undo.reason ?? "")

        // The prior body is in the sidecar, mode 0600, and nowhere in the log.
        let sidecar = sandbox.stateDir + "/" + (entry.undo.sidecar ?? "")
        XCTAssertTrue(try String(contentsOfFile: sidecar, encoding: .utf8).contains("kept private"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: sidecar)[.posixPermissions] as? Int, 0o600)
        XCTAssertFalse(sandbox.logText().contains("kept private"))
        XCTAssertFalse(sandbox.logText().contains("replacement text"))

        let undone = await undo(entry.id, runner: runner)
        XCTAssertNil(code(undone))
        XCTAssertEqual(item["body"], .string(priorBody))
        XCTAssertTrue(runner.calls.last?.contains("--html") == true, "the prior body goes back as HTML")
        assertRealCommands(runner.calls)
    }

    func testAVeryLargeNoteBodyIsNotUndoable() async throws {
        let item = FakeItem(["id": .string("n1"), "title": .string("Big"), "body": .string(String(repeating: "x", count: Undo.maxNoteBodyBytes + 1))], flags: Self.noteFlags)
        let entry = try await act("notes_edit", .object(["id": .string("n1"), "body": .string("small")]), runner: item.runner)
        XCTAssertFalse(entry.undo.supported)
    }

    // MARK: - Mail

    private func mailRunner(details: [String: String]) -> FakeRunner {
        let data = JSONValue.object(["success": .bool(true), "action": .string("x"), "details": .object(details.mapValues { .string($0) })])
        let text = ArgRedactor.canonicalJSON(.object(["v": .int(4), "status": .string("ok"), "duration_ms": .int(1), "data": data]))
        return FakeRunner { _ in (text, false) }
    }

    func testUndoMailMarkRestoresThePreviousReadState() async throws {
        let runner = mailRunner(details: ["messageId": "A||INBOX||7", "readStatus": "true", "previousReadStatus": "false", "rfcMessageId": "m7@example.com"])
        let entry = try await act("mail_mark", .object(["messageId": .string("A||INBOX||7"), "read": .bool(true)]), runner: runner)
        XCTAssertTrue(entry.undo.supported, entry.undo.reason ?? "")
        let undone = await undo(entry.id, runner: runner)
        XCTAssertNil(code(undone))
        // The inverse checks the message's identity itself, in the same script that writes.
        XCTAssertEqual(runner.calls.last, ["mail", "mark", "A||INBOX||7", "--unread", "--expect-message-id=m7@example.com", "--format", "agent"])
        assertRealCommands(runner.calls)
    }

    func testAMarkThatChangedNothingIsNotUndoable() async throws {
        let runner = mailRunner(details: ["readStatus": "true", "previousReadStatus": "true", "rfcMessageId": "m7@example.com"])
        let entry = try await act("mail_mark", .object(["messageId": .string("A||INBOX||7"), "read": .bool(true)]), runner: runner)
        XCTAssertFalse(entry.undo.supported)
    }

    func testUndoMailMoveMovesBackFindingTheMessageByMessageID() async throws {
        let runner = mailRunner(details: [
            "messageId": "A||INBOX||7", "from": "INBOX", "to": "Trash", "toResolved": "Deleted Messages", "rfcMessageId": "m7@example.com",
        ])
        let entry = try await act("mail_move", .object(["messageId": .string("A||INBOX||7"), "to": .string("Trash")]), runner: runner)
        XCTAssertTrue(entry.undo.supported, entry.undo.reason ?? "")
        let undone = await undo(entry.id, runner: runner)
        XCTAssertNil(code(undone))
        XCTAssertEqual(runner.calls.last, [
            "mail", "move", "A||Deleted Messages||0", "--to=INBOX", "--expect-message-id=m7@example.com",
            "--locate-by-message-id", "--format", "agent",
        ])
        assertRealCommands(runner.calls)
    }

    func testAMoveWithNoMessageIDIsNotUndoable() async throws {
        let runner = mailRunner(details: ["messageId": "A||INBOX||7", "from": "INBOX", "toResolved": "Archive", "rfcMessageId": ""])
        let entry = try await act("mail_move", .object(["messageId": .string("A||INBOX||7"), "to": .string("Archive")]), runner: runner)
        XCTAssertFalse(entry.undo.supported)
    }

    // MARK: - What cannot be undone

    func testIrreversibleActionsSayWhy() async throws {
        try sandbox.writePolicy(#"{"rules": {"*": "allow"}}"#)
        let runner = FakeRunner()
        let calls: [(String, JSONValue)] = [
            ("mail_send", .object(["to": .array([.string("a@example.com")]), "subject": .string("s"), "body": .string("b"), "confirm": .bool(true)])),
            ("messages_send", .object(["to": .string("+15551234567"), "body": .string("b")])),
            ("notes_delete", .object(["id": .string("n1"), "confirm": .bool(true)])),
            ("reminders_create", .object(["title": .string("t")])),
            ("mail_apply_rules", .object(["confirm": .bool(true)])),
        ]
        for (tool, args) in calls {
            let entry = try await act(tool, args, runner: runner)
            XCTAssertEqual(entry.outcome, "success", tool)
            XCTAssertFalse(entry.undo.supported, tool)
            XCTAssertFalse((entry.undo.reason ?? "").isEmpty, tool)
            let result = await undo(entry.id, runner: runner)
            XCTAssertEqual(code(result), "undo_not_supported", tool)
        }
    }

    func testUnknownActionIdIsATypedError() async {
        let result = await undo("nope", runner: FakeRunner())
        XCTAssertEqual(code(result), "action_not_found")
    }

    func testAFailedInverseIsReportedAndTheActionStaysUndoable() async throws {
        let item = FakeItem(["id": .string("REMINDER-FULL-ID"), "isCompleted": .bool(false)], flags: Self.reminderFlags)
        let entry = try await act("reminders_complete", .object(["id": .string("REMINDER-FULL-ID")]), runner: item.runner)
        let failing = FakeRunner { argv in
            argv.contains("show") ? item.respond(argv)
                : (#"{"v":4,"status":"error","duration_ms":1,"error":{"code":"save_failed","message":"disk","next_step":{"retryable":false}}}"#, true)
        }
        let result = await undo(entry.id, runner: failing)
        XCTAssertEqual(code(result), "undo_failed")
        XCTAssertFalse(try XCTUnwrap(ActionLog(path: sandbox.logPath).entries().first).undone)
    }

    // MARK: - The undo tool

    func testTheUndoToolIsItselfGatedAndLogged() async throws {
        let runner = FakeRunner()
        let entry = try await act("undo", .object(["id": .string("abc123")]), runner: runner)
        XCTAssertEqual(runner.calls, [["undo", "--format", "agent", "abc123"]])
        XCTAssertEqual(entry.tool, "undo")
        XCTAssertEqual(entry.rule, "allow")
        XCTAssertFalse(entry.undo.supported, "an undo cannot itself be undone")

        try sandbox.writePolicy(#"{"rules": {"undo": "deny"}}"#)
        let denied = await sandbox.gate().attempt("undo", .object(["id": .string("abc123")]), runner: runner)
        XCTAssertEqual(denied.code, "policy_denied")
        XCTAssertEqual(runner.calls.count, 1)
    }
}
