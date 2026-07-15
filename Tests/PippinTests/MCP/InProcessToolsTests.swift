@testable import PippinLib
import XCTest

/// Tests for the in-process MCP tool dispatch (pippin-dd3): the safe EventKit /
/// CNContactStore read tools run inside the server process instead of spawning
/// a `pippin <cmd> --format agent` child, but must produce the exact same
/// envelope-v1 JSON.
///
/// Live-store tests are headless-safe: on an unauthorized machine the bridge
/// throws `accessDenied`, which the dispatcher must wrap into the same
/// `{"v":1,"status":"error",...}` envelope the child would print — an equally
/// valid envelope-v1 parity check.
final class InProcessToolsTests: XCTestCase {
    /// The read-only tools migrated off the child path this round.
    static let migratedTools: Set<String> = [
        "calendar_list", "calendar_events", "calendar_today",
        "calendar_remaining", "calendar_upcoming", "calendar_search",
        "reminders_lists", "reminders_list", "reminders_show", "reminders_search",
        "contacts_search", "contacts_show",
    ]

    // MARK: - Registry wiring

    func testRegistryToolCount() {
        XCTAssertEqual(
            MCPToolRegistry.tools.count, 47,
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

    func testOkEnvelopeMatchesEnvelopeV1Frame() throws {
        let text = try MCPInProcessTools.okEnvelope(["k": "v"], startedAt: Date())
        let envelope = try decodeObject(text)
        XCTAssertEqual(envelope["v"] as? Int, 1)
        XCTAssertEqual(envelope["status"] as? String, "ok")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(envelope["duration_ms"] as? Int), 0)
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        XCTAssertEqual(data["k"] as? String, "v")
        XCTAssertNil(envelope["warnings"], "warnings must be omitted when nil")
    }

    func testOkEnvelopeCarriesWarnings() throws {
        let text = try MCPInProcessTools.okEnvelope([1, 2], startedAt: Date(), warnings: ["partial"])
        let envelope = try decodeObject(text)
        XCTAssertEqual(envelope["warnings"] as? [String], ["partial"])
    }

    func testErrorEnvelopeUsesAgentErrorCodeDerivation() throws {
        let text = MCPInProcessTools.errorEnvelope(CalendarBridgeError.accessDenied, startedAt: Date())
        let envelope = try decodeObject(text)
        XCTAssertEqual(envelope["v"] as? Int, 1)
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
            description: "test double",
            inputSchema: Schema.empty,
            buildArgs: { _ in ["fake", "--format", "agent"] },
            inProcess: { _ in throw BoomError() }
        )
        let (text, isError) = try await callTool("fake_tool", tools: [fake])
        XCTAssertTrue(isError)
        let envelope = try decodeObject(text)
        XCTAssertEqual(envelope["v"] as? Int, 1)
        XCTAssertEqual(envelope["status"] as? String, "error")
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "boom_error")
        XCTAssertEqual(error["message"] as? String, "boom")
    }

    func testInProcessToolArgErrorMatchesChildPathShape() async throws {
        // buildArgs still validates arguments for in-process tools, so a missing
        // required arg yields the same "Argument error: …" text as the child path.
        let (text, isError) = try await callTool("reminders_show")
        XCTAssertTrue(isError)
        XCTAssertTrue(text.hasPrefix("Argument error:"), "got: \(text)")
        XCTAssertTrue(text.contains("id"))
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
        let (text, isError) = try await callTool(
            "calendar_events",
            arguments: #"{"from":"not-a-date"}"#
        )
        XCTAssertTrue(isError)
        let envelope = try decodeObject(text)
        XCTAssertEqual(envelope["status"] as? String, "error")
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        // Bad input never reaches the bridge, so this holds even headless.
        XCTAssertEqual(error["code"] as? String, "wrong_type")
        XCTAssertTrue((error["message"] as? String ?? "").contains("from"))
    }

    // MARK: - Helpers

    private func decodeObject(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any], "expected a JSON object, got: \(text)")
    }

    /// Dispatch a tools/call through `MCPDispatcher` and return the tool result
    /// text. `pippinPath` is a poison pill (`/usr/bin/false`): if the tool were
    /// dispatched to a child by mistake, the result would be a non-JSON "exited
    /// 1 with no output" string and the envelope assertions would fail.
    private func callTool(
        _ name: String,
        arguments: String = "{}",
        tools: [MCPTool] = MCPToolRegistry.tools
    ) async throws -> (text: String, isError: Bool) {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(json.utf8))
        let maybeResponse = await MCPDispatcher.handle(request, pippinPath: "/usr/bin/false", tools: tools)
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
        XCTAssertEqual(envelope["v"] as? Int, 1, file: file, line: line)
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
