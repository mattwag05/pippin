import Foundation
@testable import PippinLib
import XCTest

/// The safety controls as an MCP client meets them: through `MCPDispatcher`,
/// the same entry point the server loop calls.
final class SafetyDispatcherTests: XCTestCase {
    private var sandbox = SafetySandbox()

    override func setUp() {
        sandbox = SafetySandbox()
    }

    override func tearDown() {
        sandbox.remove()
    }

    private struct Reply {
        let isError: Bool
        let envelope: [String: Any]
        var error: [String: Any]? { envelope["error"] as? [String: Any] }
        var code: String? { error?["code"] as? String }
    }

    private func call(
        _ tool: String, _ arguments: [String: Any], gate: SafetyGate, runner: FakeRunner, tools: [MCPTool] = MCPToolRegistry.tools
    ) async throws -> Reply {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: JSONSerialization.data(withJSONObject: body))
        // pippinPath is never used: `runner` stands in for the child.
        let response = await MCPDispatcher.handle(request, pippinPath: "/usr/bin/false", tools: tools, safety: gate, runner: runner.run)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(response))) as? [String: Any])
        let result = try XCTUnwrap(root["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        return try Reply(
            isError: XCTUnwrap(result["isError"] as? Bool),
            envelope: XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        )
    }

    private let send: [String: Any] = ["to": ["a@example.com"], "subject": "Lunch", "body": "See you at noon", "confirm": true]

    /// The headline guarantee: under the default policy a send does not happen
    /// until a valid token comes back with the same arguments.
    func testMailSendUnderDefaultPolicyDoesNotActUntilAValidTokenIsPresented() async throws {
        let runner = FakeRunner()
        let gate = sandbox.gate()

        let first = try await call("mail_send", send, gate: gate, runner: runner)
        XCTAssertTrue(first.isError)
        XCTAssertEqual(first.code, "confirmation_required")
        let details = try XCTUnwrap(first.error?["details"] as? [String: Any])
        let token = try XCTUnwrap(details["confirmToken"] as? String)
        XCTAssertTrue((details["summary"] as? String)?.contains("a@example.com") == true)
        XCTAssertNotNil(details["expires_at"] as? String)
        XCTAssertNotNil(details["preview"])
        let step = try XCTUnwrap(first.error?["next_step"] as? [String: Any])
        XCTAssertEqual(step["retryable"] as? Bool, false)
        XCTAssertTrue((step["human_action"] as? String)?.contains("confirmToken") == true)
        // The only child so far is the tool's own dry run.
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.actingCalls, [])

        for bad in ["wrong-token", ""] {
            let refused = try await call("mail_send", send.merging(["confirmToken": bad]) { $1 }, gate: gate, runner: runner)
            XCTAssertTrue(refused.isError, bad)
        }
        let changed = try await call("mail_send", send.merging(["confirmToken": token, "subject": "Other"]) { $1 }, gate: gate, runner: runner)
        XCTAssertEqual(changed.code, "confirm_token_mismatch")
        XCTAssertEqual(runner.actingCalls, [], "nothing but previews before a valid token")

        let confirmed = try await call("mail_send", send.merging(["confirmToken": token]) { $1 }, gate: gate, runner: runner)
        XCTAssertFalse(confirmed.isError)
        XCTAssertEqual(runner.actingCalls.count, 1)
        XCTAssertEqual(runner.actingCalls[0].prefix(2), ["mail", "send"])
        XCTAssertTrue(runner.actingCalls[0].contains("--confirm"))

        let replay = try await call("mail_send", send.merging(["confirmToken": token]) { $1 }, gate: gate, runner: runner)
        XCTAssertEqual(replay.code, "confirm_token_reused")
        XCTAssertEqual(runner.actingCalls.count, 1)
    }

    func testEveryDefaultConfirmToolIsHeldAtTheDispatcher() async throws {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let calls: [(String, [String: Any])] = [
            ("mail_reply", ["messageId": "a||b||1", "body": "ok", "confirm": true]),
            ("mail_forward", ["messageId": "a||b||1", "to": ["a@example.com"], "confirm": true]),
            ("messages_send", ["to": "+15551234567", "body": "hi"]),
            ("calendar_delete", ["id": "E1", "confirm": true]),
            ("reminders_delete", ["id": "R1", "confirm": true]),
            ("contacts_delete", ["identifier": "C1", "confirm": true]),
            ("notes_delete", ["id": "N1", "confirm": true]),
            ("memos_delete", ["id": "M1", "confirm": true]),
        ]
        for (tool, arguments) in calls {
            let reply = try await call(tool, arguments, gate: gate, runner: runner)
            XCTAssertEqual(reply.code, "confirmation_required", tool)
        }
        XCTAssertEqual(runner.actingCalls, [])
    }

    func testDenyAndRateLimitEnvelopes() async throws {
        try sandbox.writePolicy(#"{"rules": {"messages_*": "deny"}, "limits": {"mail_mark": {"max": 1, "per_seconds": 600}}}"#)
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let denied = try await call("messages_send", ["to": "+15551234567", "body": "hi"], gate: gate, runner: runner)
        XCTAssertEqual(denied.code, "policy_denied")
        XCTAssertEqual((denied.error?["next_step"] as? [String: Any])?["retryable"] as? Bool, false)
        let deniedRead = try await call("messages_list", [:], gate: gate, runner: runner)
        XCTAssertEqual(deniedRead.code, "policy_denied")
        XCTAssertEqual(runner.calls, [])

        _ = try await call("mail_mark", ["messageId": "a||b||1", "read": true], gate: gate, runner: runner)
        let limited = try await call("mail_mark", ["messageId": "a||b||1", "read": true], gate: gate, runner: runner)
        XCTAssertEqual(limited.code, "rate_limited")
        let step = try XCTUnwrap(limited.error?["next_step"] as? [String: Any])
        XCTAssertEqual(step["retryable"] as? Bool, true)
        XCTAssertEqual(step["retry_after_seconds"] as? Int, 600)
        XCTAssertEqual(runner.actingCalls.count, 1)
    }

    func testReadsAreNotLoggedAndDoNotTakeReservedArguments() async throws {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let read = try await call("mail_list", [:], gate: gate, runner: runner)
        XCTAssertFalse(read.isError)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.logPath))

        let reserved = try await call("mail_list", ["confirmToken": "x"], gate: gate, runner: runner)
        XCTAssertEqual(reserved.code, "unexpected_argument")
    }

    func testIdempotentReplayThroughTheDispatcher() async throws {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let arguments: [String: Any] = ["messageId": "a||b||1", "read": true, "idempotencyKey": "job-42"]
        let first = try await call("mail_mark", arguments, gate: gate, runner: runner)
        XCTAssertNil(first.envelope["replayed"])
        let second = try await call("mail_mark", arguments, gate: gate, runner: runner)
        XCTAssertFalse(second.isError)
        XCTAssertEqual(second.envelope["replayed"] as? Bool, true)
        XCTAssertEqual(runner.actingCalls.count, 1)
    }

    /// A tool nobody classified is treated as mutating, so it is gated and logged.
    func testAnUnclassifiedToolGoesThroughTheGate() async throws {
        let tool = MCPTool(name: "mystery_tool", description: "", inputSchema: Schema.empty, buildArgs: { _ in ["mystery", "--format", "agent"] })
        let runner = FakeRunner()
        let reply = try await call("mystery_tool", [:], gate: sandbox.gate(), runner: runner, tools: [tool])
        XCTAssertFalse(reply.isError)
        XCTAssertEqual(sandbox.logLines().map(\.phase), ["intent", "outcome"])
    }

    func testEveryMutatingToolIsLoggedAtTheOneChokepoint() async throws {
        try sandbox.writePolicy(#"{"rules": {"*": "deny"}}"#)
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let mutating = MCPToolRegistry.tools.filter { $0.effect != .readOnly }
        for tool in mutating {
            let reply = try await call(tool.name, [:], gate: gate, runner: runner)
            XCTAssertEqual(reply.code, "policy_denied", tool.name)
        }
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(Set(ActionLog(path: sandbox.logPath).entries().map(\.tool)), Set(mutating.map(\.name)))
    }

    func testToolsListAdvertisesReservedArgumentsOnMutatingToolsOnly() async throws {
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        let response = await MCPDispatcher.handle(request, pippinPath: "/usr/bin/false")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(response))) as? [String: Any])
        let listed = try XCTUnwrap((root["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        for tool in MCPToolRegistry.tools {
            let schema = try XCTUnwrap(listed.first { $0["name"] as? String == tool.name }?["inputSchema"] as? [String: Any])
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for name in SafetyGate.reservedArguments {
                XCTAssertEqual(properties[name] != nil, tool.effect != .readOnly, "\(tool.name).\(name)")
            }
        }
    }

    func testNewToolsAreRegistered() throws {
        XCTAssertEqual(try safetyTool("policy_show").effect, .readOnly)
        XCTAssertEqual(try safetyTool("action_log").effect, .readOnly)
        XCTAssertEqual(try safetyTool("undo").effect, .mutating(verifyWith: "action_log"))
        XCTAssertEqual(
            try safetyTool("action_log").buildArgs(.object(["limit": .int(5), "since": .string("2026-11-01"), "tool": .string("mail_send")])),
            ["log", "--format", "agent", "--limit=5", "--since=2026-11-01", "--tool=mail_send"]
        )
    }
}
