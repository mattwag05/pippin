@testable import PippinLib
import XCTest

final class ToolRegistryTests: XCTestCase {
    func testRegistryHasExpectedTools() {
        // Should cover the morning-briefing consumer tools plus write-path tools.
        let names = Set(MCPToolRegistry.tools.map { $0.name })
        XCTAssertTrue(names.contains("mail_list"))
        XCTAssertTrue(names.contains("mail_accounts"))
        XCTAssertTrue(names.contains("calendar_today"))
        XCTAssertTrue(names.contains("calendar_upcoming"))
        XCTAssertTrue(names.contains("reminders_list"))
        XCTAssertTrue(names.contains("reminders_create"))
        XCTAssertTrue(names.contains("status"))
        XCTAssertTrue(names.contains("doctor"))
    }

    func testToolNamesAreUniqueAndSnakeCase() {
        let names = MCPToolRegistry.tools.map { $0.name }
        XCTAssertEqual(names.count, Set(names).count, "Duplicate tool names in registry")

        let snakeCase = /^[a-z][a-z0-9_]*$/
        for name in names {
            XCTAssertNotNil(try? snakeCase.wholeMatch(in: name), "Tool name '\(name)' is not snake_case")
        }
    }

    func testInputSchemasAreEncodableJSONSchemaObjects() throws {
        let encoder = JSONEncoder()
        for tool in MCPToolRegistry.tools {
            let data = try encoder.encode(tool.inputSchema)
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(decoded, "Schema for \(tool.name) does not encode to object")
            XCTAssertEqual(decoded?["type"] as? String, "object", "Schema for \(tool.name) missing type=object")
            XCTAssertNotNil(decoded?["properties"], "Schema for \(tool.name) missing properties")
        }
    }

    func testBuildArgsForMailListMapsAllFields() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "mail_list"))
        let args: JSONValue = .object([
            "account": .string("iCloud"),
            "mailbox": .string("Work"),
            "unread": .bool(true),
            "limit": .int(5),
            "page": .int(2),
        ])
        let argv = try tool.buildArgs(args)
        XCTAssertEqual(argv.first, "mail")
        XCTAssertEqual(argv[1], "list")
        XCTAssertTrue(argv.contains("--format"))
        XCTAssertTrue(argv.contains("agent"))
        XCTAssertTrue(argv.contains("--account"))
        XCTAssertTrue(argv.contains("iCloud"))
        XCTAssertTrue(argv.contains("--mailbox"))
        XCTAssertTrue(argv.contains("Work"))
        XCTAssertTrue(argv.contains("--unread"))
        XCTAssertTrue(argv.contains("--limit"))
        XCTAssertTrue(argv.contains("5"))
        XCTAssertTrue(argv.contains("--page"))
        XCTAssertTrue(argv.contains("2"))
    }

    func testBuildArgsForMailListOmitsAbsentFields() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "mail_list"))
        let argv = try tool.buildArgs(.object([:]))
        XCTAssertFalse(argv.contains("--account"))
        XCTAssertFalse(argv.contains("--mailbox"))
        XCTAssertFalse(argv.contains("--unread"))
        XCTAssertFalse(argv.contains("--limit"))
    }

    func testBuildArgsForMailSearchRequiresQuery() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "mail_search"))
        XCTAssertThrowsError(try tool.buildArgs(.object([:]))) { error in
            guard case MCPToolArgError.missingRequired("query") = error else {
                return XCTFail("Expected missingRequired(\"query\"), got \(error)")
            }
        }
    }

    func testBuildArgsForMailShowAcceptsEitherIdOrSubject() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "mail_show"))
        let argvWithId = try tool.buildArgs(.object(["messageId": .string("acct||INBOX||42")]))
        XCTAssertTrue(argvWithId.contains("acct||INBOX||42"))

        let argvWithSubject = try tool.buildArgs(.object(["subject": .string("Hello")]))
        XCTAssertTrue(argvWithSubject.contains("--subject"))
        XCTAssertTrue(argvWithSubject.contains("Hello"))

        XCTAssertThrowsError(try tool.buildArgs(.object([:])))
    }

    func testBuildArgsForRemindersCreate() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "reminders_create"))
        let argv = try tool.buildArgs(.object([
            "title": .string("Buy milk"),
            "due": .string("2026-04-15"),
            "priority": .string("high"),
        ]))
        XCTAssertEqual(argv[0], "reminders")
        XCTAssertEqual(argv[1], "create")
        XCTAssertTrue(argv.contains("Buy milk"))
        XCTAssertTrue(argv.contains("--due"))
        XCTAssertTrue(argv.contains("2026-04-15"))
        XCTAssertTrue(argv.contains("--priority"))
        XCTAssertTrue(argv.contains("high"))
    }

    func testEmptySchemaToolsProduceSimpleArgv() throws {
        let status = try XCTUnwrap(MCPToolRegistry.tool(named: "status"))
        XCTAssertEqual(try status.buildArgs(nil), ["status", "--format", "agent"])

        let doctor = try XCTUnwrap(MCPToolRegistry.tool(named: "doctor"))
        XCTAssertEqual(try doctor.buildArgs(nil), ["doctor", "--format", "agent"])
    }

    func testAllArgvEndWithFormatAgent() {
        // Every tool must pass --format agent so stdout is compact JSON.
        for tool in MCPToolRegistry.tools {
            // Build with a permissive arg set so required-field tools don't throw.
            let args = sampleArgs(for: tool.name)
            guard let argv = try? tool.buildArgs(args) else {
                XCTFail("Could not build argv for \(tool.name)")
                continue
            }
            XCTAssertTrue(
                argv.contains("--format"),
                "\(tool.name) argv missing --format"
            )
            XCTAssertTrue(
                argv.contains("agent"),
                "\(tool.name) argv missing 'agent'"
            )
        }
    }

    private func sampleArgs(for name: String) -> JSONValue {
        // Provide synthetic required fields for tools that demand them.
        switch name {
        case "mail_search", "calendar_search", "reminders_search", "contacts_search", "notes_search":
            return .object(["query": .string("x")])
        case "mail_show":
            return .object(["messageId": .string("a||b||1")])
        case "reminders_show", "reminders_complete":
            return .object(["id": .string("123")])
        case "notes_show":
            return .object(["id": .string("123")])
        case "contacts_show":
            return .object(["identifier": .string("123")])
        case "calendar_create":
            return .object(["title": .string("X"), "start": .string("2026-04-15")])
        case "reminders_create":
            return .object(["title": .string("X")])
        case "memos_info":
            return .object(["id": .string("abc-123")])
        case "memos_export":
            return .object(["id": .string("abc-123"), "output": .string("/tmp/out")])
        case "memos_transcribe", "memos_summarize":
            return .object(["id": .string("abc-123")])
        case "batch":
            return .object(["entries": .array([
                .object(["cmd": .string("doctor")]),
            ])])
        case "job_run":
            return .object(["argv": .array([.string("doctor")])])
        case "job_show", "job_wait":
            return .object(["id": .string("abc")])
        default:
            return .object([:])
        }
    }

    // MARK: - Memos tools

    func testMemosToolsRegistered() {
        let names = Set(MCPToolRegistry.tools.map { $0.name })
        XCTAssertTrue(names.contains("memos_list"))
        XCTAssertTrue(names.contains("memos_info"))
        XCTAssertTrue(names.contains("memos_export"))
        XCTAssertTrue(names.contains("memos_transcribe"))
        XCTAssertTrue(names.contains("memos_summarize"))
    }

    func testMemosExportRequiresOutput() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "memos_export"))
        XCTAssertThrowsError(try tool.buildArgs(.object(["id": .string("x")]))) { error in
            guard case MCPToolArgError.missingRequired("output") = error else {
                return XCTFail("Expected missingRequired(\"output\"), got \(error)")
            }
        }
    }

    func testMemosTranscribeAcceptsEitherIdOrAll() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "memos_transcribe"))
        let withID = try tool.buildArgs(.object(["id": .string("abc-123")]))
        XCTAssertTrue(withID.contains("abc-123"))
        XCTAssertFalse(withID.contains("--all"))

        let withAll = try tool.buildArgs(.object(["all": .bool(true)]))
        XCTAssertTrue(withAll.contains("--all"))

        XCTAssertThrowsError(try tool.buildArgs(.object([:])))
    }

    // MARK: - Jobs tools

    func testJobToolsRegistered() {
        let names = Set(MCPToolRegistry.tools.map { $0.name })
        XCTAssertTrue(names.contains("job_run"))
        XCTAssertTrue(names.contains("job_show"))
        XCTAssertTrue(names.contains("job_list"))
        XCTAssertTrue(names.contains("job_wait"))
    }

    func testJobRunBuildsArgvWithTerminator() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "job_run"))
        let argv = try tool.buildArgs(.object(["argv": .array([
            .string("mail"), .string("index"),
        ])]))
        XCTAssertEqual(argv[0], "job")
        XCTAssertEqual(argv[1], "run")
        XCTAssertTrue(argv.contains("--"))
        XCTAssertTrue(argv.contains("mail"))
        XCTAssertTrue(argv.contains("index"))
        XCTAssertTrue(argv.contains("--format"))
        XCTAssertTrue(argv.contains("agent"))
    }

    func testJobRunRequiresArgv() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "job_run"))
        XCTAssertThrowsError(try tool.buildArgs(.object([:]))) { error in
            guard case MCPToolArgError.missingRequired("argv") = error else {
                return XCTFail("Expected missingRequired(argv), got \(error)")
            }
        }
    }

    func testJobShowRequiresId() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "job_show"))
        XCTAssertThrowsError(try tool.buildArgs(.object([:])))
    }

    func testJobWaitPassesTimeout() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "job_wait"))
        let argv = try tool.buildArgs(.object([
            "id": .string("abc"),
            "timeout": .int(60),
        ]))
        XCTAssertTrue(argv.contains("abc"))
        XCTAssertTrue(argv.contains("--timeout"))
        XCTAssertTrue(argv.contains("60"))
    }
}
