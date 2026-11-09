import ArgumentParser
@testable import PippinLib
import XCTest

/// Default row trimming (pippin-w5j3), MCP list options, and the mail send gate.
final class DefaultFieldsTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func options(_ argv: [String]) throws -> OutputOptions {
        try OutputOptions.parse(argv)
    }

    private let mail = MailMessage(
        id: "a||b||1", account: "a", mailbox: "b", subject: "s", from: "f", to: ["t"],
        date: "2026-01-01T00:00:00.000Z", read: false, size: 9, hasAttachment: true,
        bodyPreview: "p", fromContact: "c"
    )

    private func keys(_ value: some Encodable) throws -> Set<String> {
        try Set(XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]).keys)
    }

    /// A typo in an essential key would silently drop that field from every row.
    func testEssentialFieldsAreRealKeys() throws {
        let event = CalendarEvent(
            id: "1", calendarId: "c", calendarTitle: "C", title: "t", startDate: "s", endDate: "e",
            isAllDay: false, location: "l"
        )
        let reminder = ReminderItem(id: "1", listId: "l", listTitle: "L", title: "t", dueDate: "d", priority: 1)
        let note = NoteInfo(
            id: "1", title: "t", plainText: "p", folder: "f", folderId: "i",
            creationDate: "c", modificationDate: "m"
        )
        let conversation = MessageConversation(
            id: "1", service: "s", displayName: "d", participants: [], isGroup: false,
            lastMessageAt: "l", lastMessagePreview: "p", unreadCount: 0
        )
        let memo = VoiceMemo(
            id: "1", title: "t", durationSeconds: 1, createdAt: Date(), filePath: "/p"
        )
        try XCTAssertTrue(Set(MailMessage.essentialFields).isSubset(of: keys(mail)))
        try XCTAssertTrue(Set(CalendarEvent.essentialFields).isSubset(of: keys(event)))
        try XCTAssertTrue(Set(ReminderItem.essentialFields).isSubset(of: keys(reminder)))
        try XCTAssertTrue(Set(NoteInfo.essentialFields).isSubset(of: keys(note)))
        try XCTAssertTrue(Set(MessageConversation.essentialFields).isSubset(of: keys(conversation)))
        try XCTAssertTrue(Set(VoiceMemo.essentialFields).isSubset(of: keys(memo)))
    }

    func testArrayRowsTrimByDefault() throws {
        let envelope = try json(options([]).render(AgentResult([mail])))
        let row = try XCTUnwrap((envelope["data"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["subject"] as? String, "s")
        XCTAssertNil(row["to"])
        XCTAssertNil(row["size"])
        XCTAssertNil(envelope["warnings"])
    }

    func testPagesTrimAndKeepCursor() throws {
        let page = Page(items: [mail], nextCursor: "abc")
        let envelope = try json(options([]).render(.emitPage(page, timedOutHint: "")))
        XCTAssertEqual(envelope["next_cursor"] as? String, "abc")
        XCTAssertNil((envelope["data"] as? [[String: Any]])?.first?["to"])
    }

    func testFieldsAllReturnsWholeRows() throws {
        let envelope = try json(options(["--fields", "all"]).render(AgentResult([mail])))
        XCTAssertNotNil((envelope["data"] as? [[String: Any]])?.first?["to"])
    }

    func testExplicitFieldsOverrideTheDefault() throws {
        let envelope = try json(options(["--fields", "size"]).render(AgentResult([mail])))
        let row = try XCTUnwrap((envelope["data"] as? [[String: Any]])?.first)
        XCTAssertEqual(Array(row.keys), ["size"])
    }

    func testSingleObjectsAndUntrimmedArraysStayWhole() throws {
        let single = try json(options([]).render(AgentResult(mail)))
        XCTAssertNotNil((single["data"] as? [String: Any])?["to"])
        let batch = try json(options([]).render(AgentResult([mail], untrimmed: true)))
        XCTAssertNotNil((batch["data"] as? [[String: Any]])?.first?["to"])
    }

    func testRequestedFieldInNoRowWarns() throws {
        let envelope = try json(options(["--fields", "subject,sujbect"]).render(AgentResult([mail])))
        let warnings = try XCTUnwrap(envelope["warnings"] as? [String])
        XCTAssertTrue(warnings.contains { $0.contains("sujbect") })
        XCTAssertFalse(warnings.contains { $0.contains("subject,") })
    }

    func testEmptyResultDoesNotWarnAboutFields() throws {
        let envelope = try json(options(["--fields", "subject"]).render(AgentResult([MailMessage]())))
        XCTAssertNil(envelope["warnings"])
    }

    // MARK: - MCP list options

    private func tool(_ name: String) throws -> MCPTool {
        try XCTUnwrap(MCPToolRegistry.tool(named: name))
    }

    func testProjectableToolsExposeFields() throws {
        for name in ["mail_activity", "calendar_today", "reminders_search", "notes_search", "messages_list", "memos_list"] {
            let properties = try tool(name).inputSchema["properties"]
            XCTAssertNotNil(properties?["fields"], name)
        }
    }

    func testPagedToolsExposeCursorAndOthersDoNot() throws {
        for name in ["mail_list", "mail_search", "calendar_events", "reminders_list", "contacts_search", "notes_list", "memos_list"] {
            XCTAssertNotNil(try tool(name).inputSchema["properties"]?["cursor"], name)
        }
        XCTAssertNil(try tool("notes_search").inputSchema["properties"]?["cursor"])
    }

    func testListOptionsStayAheadOfTrailingPositional() throws {
        let args: JSONValue = .object(["query": .string("q"), "fields": .string("id"), "cursor": .string("c")])
        let argv = try tool("contacts_search").buildArgs(args)
        let terminator = try XCTUnwrap(argv.firstIndex(of: "--"))
        XCTAssertLessThan(try XCTUnwrap(argv.firstIndex { $0.hasPrefix("--cursor") }), terminator)
        XCTAssertEqual(argv.last, "q")
    }

    // MARK: - Send gate

    private let sendArgs = ["--to", "a@b.c", "--subject", "s", "--body", "b"]

    func testMailSendPreviewsUnlessConfirmed() throws {
        XCTAssertFalse(try MailCommand.Send.parse(sendArgs).confirm)
        XCTAssertTrue(try MailCommand.Send.parse(sendArgs + ["--confirm"]).confirm)
    }

    func testMCPSendGateMapsConfirm() throws {
        let send = try tool("mail_send")
        let base: [String: JSONValue] = ["to": .array([.string("a@b.c")]), "subject": .string("s"), "body": .string("b")]
        let preview = try send.buildArgs(.object(base))
        XCTAssertTrue(preview.contains("--dry-run"))
        XCTAssertFalse(preview.contains("--confirm"))
        var confirmed = base
        confirmed["confirm"] = .bool(true)
        let real = try send.buildArgs(.object(confirmed))
        XCTAssertTrue(real.contains("--confirm"))
        XCTAssertFalse(real.contains("--dry-run"))
    }
}
