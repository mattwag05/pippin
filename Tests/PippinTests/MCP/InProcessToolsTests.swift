@testable import PippinLib
import XCTest

/// Tests for the in-process MCP tool dispatch (pippin-dd3): the safe EventKit /
/// CNContactStore read tools run inside the server process instead of spawning
/// a `pippin <cmd> --format agent` child, but must produce the exact same
/// envelope-v1 JSON.
///
/// Live-store tests are headless-safe: on an unauthorized machine the bridge
/// throws `accessDenied`, which the dispatcher must wrap into the same
/// `{"v":N,"status":"error",...}` envelope the child would print — an equally
/// valid envelope-v1 parity check.
final class InProcessToolsTests: XCTestCase {
    /// The read-only tools migrated off the child path this round.
    static let migratedTools: Set<String> = [
        "calendar_list", "calendar_events", "calendar_today",
        "calendar_remaining", "calendar_upcoming", "calendar_search",
        "reminders_lists", "reminders_list", "reminders_show", "reminders_search",
        "contacts_search", "contacts_show",
        "messages_list", "messages_search", "messages_show",
        "notes_list", "notes_search", "notes_show", "notes_folders",
    ]

    // MARK: - Registry wiring

    func testRegistryToolCount() {
        XCTAssertEqual(
            MCPToolRegistry.tools.count, 79,
            "update this count when adding/removing MCP tools (and docs/mcp-server.md)"
        )
    }

    func testMigratedToolsHaveInProcessHandlers() throws {
        for name in Self.migratedTools {
            let tool = try XCTUnwrap(MCPToolRegistry.tool(named: name))
            XCTAssertNotNil(tool.inProcess, "\(name) should dispatch in-process")
        }
    }

    func testAllOtherToolsStayOnChildPath() {
        for tool in MCPToolRegistry.tools where !Self.migratedTools.contains(tool.name) {
            XCTAssertNil(tool.inProcess, "\(tool.name) must stay on the child path this round")
        }
    }

    // MARK: - Envelope helpers (deterministic, no live stores)

    func testErrorEnvelopeUsesAgentErrorCodeDerivation() throws {
        let text = MCPInProcessTools.errorEnvelope(CalendarBridgeError.accessDenied, startedAt: Date())
        let envelope = try decodeObject(text)
        XCTAssertEqual(envelope["v"] as? Int, AGENT_SCHEMA_VERSION)
        XCTAssertEqual(envelope["status"] as? String, "error")
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "access_denied")
        XCTAssertNotNil(error["message"] as? String)
    }

    // MARK: - Dispatcher in-process branch (deterministic via injected tools)

    func testDispatcherReturnsInProcessResultVerbatim() async throws {
        let canned = #"{"v":1,"status":"ok","duration_ms":3,"data":[]}"#
        let fake = MCPTool(
            name: "fake_tool",
            effect: .readOnly,
            description: "test double",
            inputSchema: Schema.empty,
            buildArgs: { _ in ["fake", "--format", "agent"] },
            inProcess: { _ in canned }
        )
        let (text, isError) = try await callTool("fake_tool", tools: [fake])
        XCTAssertEqual(text, canned)
        XCTAssertFalse(isError)
    }

    func testDispatcherWrapsInProcessThrowIntoErrorEnvelope() async throws {
        struct BoomError: LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let fake = MCPTool(
            name: "fake_tool",
            effect: .readOnly,
            description: "test double",
            inputSchema: Schema.empty,
            buildArgs: { _ in ["fake", "--format", "agent"] },
            inProcess: { _ in throw BoomError() }
        )
        let (text, isError) = try await callTool("fake_tool", tools: [fake])
        XCTAssertTrue(isError)
        let envelope = try decodeObject(text)
        XCTAssertEqual(envelope["v"] as? Int, AGENT_SCHEMA_VERSION)
        XCTAssertEqual(envelope["status"] as? String, "error")
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "boom_error")
        XCTAssertEqual(error["message"] as? String, "boom")
    }

    func testInProcessToolArgErrorMatchesChildPathShape() async throws {
        // buildArgs still validates arguments for in-process tools, so a missing
        // required arg yields the same error envelope as the child path.
        let (text, isError) = try await callTool("reminders_show")
        XCTAssertTrue(isError)
        let error = try XCTUnwrap(decodeObject(text)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "missing_required")
        XCTAssertEqual(error["message"] as? String, "Missing required argument: 'id'.")
    }

    // MARK: - Live-store envelope parity (ok or access_denied, both envelope v1)

    func testCalendarTodayInProcessEnvelopeShape() async throws {
        let (text, isError) = try await callTool("calendar_today")
        let payload = try assertEnvelopeV1(text, isError: isError)
        if let payload {
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertNoThrow(
                try JSONDecoder().decode([CalendarEvent].self, from: data),
                "calendar_today data must decode as the CLI's [CalendarEvent] payload"
            )
        }
    }

    func testCalendarListInProcessEnvelopeShape() async throws {
        let (text, isError) = try await callTool("calendar_list")
        let payload = try assertEnvelopeV1(text, isError: isError)
        if let payload {
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertNoThrow(
                try JSONDecoder().decode([CalendarInfo].self, from: data),
                "calendar_list data must decode as the CLI's [CalendarInfo] payload"
            )
        }
    }

    func testRemindersListsInProcessEnvelopeShape() async throws {
        let (text, isError) = try await callTool("reminders_lists")
        let payload = try assertEnvelopeV1(text, isError: isError)
        if let payload {
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertNoThrow(
                try JSONDecoder().decode([ReminderList].self, from: data),
                "reminders_lists data must decode as the CLI's [ReminderList] payload"
            )
        }
    }

    func testContactsSearchInProcessEnvelopeShape() async throws {
        let (text, isError) = try await callTool(
            "contacts_search",
            arguments: #"{"query":"zz-no-such-contact"}"#
        )
        let payload = try assertEnvelopeV1(text, isError: isError)
        if let payload {
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertNoThrow(
                try JSONDecoder().decode([ContactInfo].self, from: data),
                "contacts_search data must decode as the CLI's [ContactInfo] payload"
            )
        }
    }

    func testCalendarEventsRejectsBadDateWithErrorEnvelope() async throws {
        // A bad date fails the command's validate() while parsing, so this holds
        // even headless: it never reaches the bridge.
        let (text, isError) = try await callTool(
            "calendar_events",
            arguments: #"{"from":"not-a-date"}"#
        )
        XCTAssertTrue(isError)
        let envelope = try decodeObject(text)
        XCTAssertEqual(envelope["v"] as? Int, AGENT_SCHEMA_VERSION)
        XCTAssertEqual(envelope["status"] as? String, "error")
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertNotNil(error["code"] as? String)
    }

    // MARK: - Deadline and demotion

    func testDeadlineReturnsTimeoutEnvelopeThenDemotesToChild() async throws {
        // The demotion set is process-global, so the name must be unique.
        let name = "deadline_tool_\(UUID().uuidString)"
        let slow = MCPTool(
            name: name,
            effect: .readOnly,
            description: "test double",
            inputSchema: Schema.empty,
            buildArgs: { _ in [] },
            inProcess: { _ in
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return "late"
            }
        )

        let first = try await callTool(name, tools: [slow], pippinPath: "/usr/bin/true", inProcessDeadline: 0.05)
        XCTAssertTrue(first.isError)
        let envelope = try decodeObject(first.text)
        XCTAssertEqual(envelope["status"] as? String, "error")
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "in_process_timed_out")

        // `/usr/bin/true` exits 0 with no stdout, which the child path maps to `{}`.
        let second = try await callTool(name, tools: [slow], pippinPath: "/usr/bin/true", inProcessDeadline: 0.05)
        XCTAssertFalse(second.isError)
        XCTAssertEqual(second.text, "{}")
    }

    // MARK: - Registry argv against the real commands

    /// Minimal valid arguments for in-process tools with required parameters. A
    /// new tool with required parameters fails in `buildArgs` until listed here.
    private static let minimalArguments: [String: String] = [
        "calendar_search": #"{"query":"zz-no-such-event"}"#,
        "reminders_show": #"{"id":"zz-no-such-reminder"}"#,
        "reminders_search": #"{"query":"zz-no-such-reminder"}"#,
        "contacts_search": #"{"query":"zz-no-such-contact"}"#,
        "contacts_show": #"{"identifier":"zz-no-such-contact"}"#,
        "messages_search": #"{"query":"zz-no-such-message","sinceHours":1}"#,
        "messages_show": #"{"conversationId":"zz-no-such-chat"}"#,
        "notes_search": #"{"query":"zz-no-such-note"}"#,
        "notes_show": #"{"id":"x-coredata://zz-no-such-note"}"#,
    ]

    private func inProcessArgvs() throws -> [(name: String, argv: [String])] {
        try MCPToolRegistry.tools.filter { $0.inProcess != nil }.map { tool in
            let json = Self.minimalArguments[tool.name] ?? "{}"
            let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            return try (tool.name, tool.buildArgs(arguments))
        }
    }

    func testEveryInProcessToolArgvParsesToAnAgentCommand() async throws {
        let tools = try inProcessArgvs()
        XCTAssertEqual(Set(tools.map(\.name)), Self.migratedTools)
        for (name, argv) in tools {
            if name.hasPrefix("notes_") {
                // Parse only: running it would read this Mac's notes and could
                // raise an Automation prompt. LiveConformanceTests runs them in the VM.
                XCTAssertNoThrow(try MCPInProcessTools.parse(argv), "\(name) argv \(argv)")
                continue
            }
            do {
                _ = try await MCPInProcessTools.withDeadline(seconds: 5) {
                    try await MCPInProcessTools.execute(argv)
                }
            } catch MCPServerRuntimeError.inProcessTimedOut {
                // Parsing runs before the store call and a usage error throws at
                // once, so a slow store (Contacts in the xctest host) still passed.
                continue
            } catch let error as MCPServerRuntimeError {
                XCTFail("\(name): \(error.localizedDescription)")
            } catch {
                // Bridge errors (no grant, no such id) are fine: they prove the command ran.
                XCTAssertFalse(
                    String(reflecting: type(of: error)).hasPrefix("ArgumentParser."),
                    "\(name) argv \(argv) is a usage error: \(error)"
                )
            }
        }
    }

    func testCLIAndInProcessEnvelopesAreEquivalent() async throws {
        CLIIntegrationTests.setUp()
        let binary = try XCTUnwrap(CLIIntegrationTests.binaryURL, "pippin binary not found; run `swift build` first")
        // Messages and Notes are left out: live data changes between the two
        // calls and a failure would print the user's conversations or notes.
        // The VM fixture run covers them.
        for (name, argv) in try inProcessArgvs() where !name.hasPrefix("messages_") && !name.hasPrefix("notes_") {
            let cli = CLIIntegrationTests.runProcess(binary.path, args: argv)
            let inProcess: String
            if name.hasPrefix("contacts_") {
                // TCC answers per process identity: in the xctest host Contacts
                // gets past the grant check and stalls on contactsd, so compare
                // against the same execute() inside a real `pippin mcp-server`.
                inProcess = try mcpServerText(binary: binary, tool: name)
            } else {
                do {
                    inProcess = try await MCPInProcessTools.execute(argv)
                } catch {
                    inProcess = MCPInProcessTools.errorEnvelope(error, startedAt: Date())
                }
            }
            var cliEnvelope = try decodeObject(cli.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            var inProcessEnvelope = try decodeObject(inProcess)
            cliEnvelope["duration_ms"] = nil
            inProcessEnvelope["duration_ms"] = nil
            XCTAssertEqual(
                NSDictionary(dictionary: cliEnvelope),
                NSDictionary(dictionary: inProcessEnvelope),
                "\(name): CLI and in-process envelopes differ"
            )
        }
    }

    private func mcpServerText(binary: URL, tool: String) throws -> String {
        let arguments = Self.minimalArguments[tool] ?? "{}"
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#
        let server = CLIIntegrationTests.runProcess(
            "/bin/sh",
            args: ["-c", #"printf '%s\n' "$1" | "$0" mcp-server"#, binary.path, request]
        )
        let response = try decodeObject(server.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let result = try XCTUnwrap(response["result"] as? [String: Any], "\(tool): \(server.stdout)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    // MARK: - Helpers

    private func decodeObject(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any], "expected a JSON object, got: \(text)")
    }

    /// Dispatch a tools/call through `MCPDispatcher` and return the tool result
    /// text. `pippinPath` defaults to a poison pill (`/usr/bin/false`): if the tool were
    /// dispatched to a child by mistake, the result would be a non-JSON "exited
    /// 1 with no output" string and the envelope assertions would fail.
    private func callTool(
        _ name: String,
        arguments: String = "{}",
        tools: [MCPTool] = MCPToolRegistry.tools,
        pippinPath: String = "/usr/bin/false",
        inProcessDeadline: Double = Double(MCPInProcessTools.deadlineSeconds)
    ) async throws -> (text: String, isError: Bool) {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let maybeResponse = await MCPDispatcher.handle(
            request, pippinPath: pippinPath, tools: tools, inProcessDeadline: inProcessDeadline
        )
        let response = try XCTUnwrap(maybeResponse)
        let data = try JSONEncoder().encode(response)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(decoded["error"], "tool calls must not surface JSON-RPC-level errors")
        let result = try XCTUnwrap(decoded["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        return (text, result["isError"] as? Bool ?? false)
    }

    /// Assert `text` is a valid envelope v1. Returns the `data` payload on
    /// success envelopes, nil on (valid) error envelopes.
    private func assertEnvelopeV1(
        _ text: String,
        isError: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Any? {
        let envelope = try decodeObject(text)
        XCTAssertEqual(envelope["v"] as? Int, AGENT_SCHEMA_VERSION, file: file, line: line)
        let duration = try XCTUnwrap(envelope["duration_ms"] as? Int, file: file, line: line)
        XCTAssertGreaterThanOrEqual(duration, 0, file: file, line: line)
        switch envelope["status"] as? String {
        case "ok":
            XCTAssertFalse(isError, file: file, line: line)
            return try XCTUnwrap(envelope["data"], "ok envelope must carry data", file: file, line: line)
        case "error":
            XCTAssertTrue(isError, file: file, line: line)
            let error = try XCTUnwrap(envelope["error"] as? [String: Any], file: file, line: line)
            let code = try XCTUnwrap(error["code"] as? String, file: file, line: line)
            XCTAssertNotNil(
                try? /^[a-z][a-z0-9_]*$/.wholeMatch(in: code),
                "error code '\(code)' must be snake_case", file: file, line: line
            )
            XCTAssertNotNil(error["message"] as? String, file: file, line: line)
            return nil
        default:
            XCTFail("unexpected envelope status in: \(text)", file: file, line: line)
            return nil
        }
    }
}
