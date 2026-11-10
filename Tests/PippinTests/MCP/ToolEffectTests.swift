@testable import PippinLib
import XCTest

/// RC-02: a timeout on a tool that changes something must not read as "retry",
/// and the timeout must take the child's whole process group with it.
final class ToolEffectTests: XCTestCase {
    private static let mutating: Set = [
        "mail_attachments", "mail_mark", "mail_move", "mail_send", "mail_reply", "mail_forward", "mail_apply_rules",
        "calendar_create", "calendar_edit", "calendar_delete", "calendar_smart_create",
        "reminders_create", "reminders_complete", "reminders_edit", "reminders_delete", "reminders_smart_create",
        "contacts_create", "contacts_edit", "contacts_delete",
        "notes_create", "notes_edit", "notes_delete",
        "messages_send", "messages_exclude_add", "messages_exclude_remove",
        "memos_export", "memos_transcribe", "memos_summarize", "memos_capture_to_reminders", "memos_delete",
        "actions_extract", "job_run", "batch", "undo",
    ]

    func testEveryRegisteredToolIsClassified() {
        let unclassified = MCPToolRegistry.tools.filter { $0.effect == nil }.map(\.name)
        XCTAssertEqual(unclassified, [], "set `effect:` on these tools in ToolRegistry")
    }

    /// Pinned, so reclassifying a tool or adding a mutating one is a deliberate edit here too.
    func testMutatingToolsAreExactlyThePinnedSet() {
        let actual = Set(MCPToolRegistry.tools.filter { $0.effect != .readOnly }.map(\.name))
        XCTAssertEqual(actual, Self.mutating)
    }

    func testWriteVerbsAreNeverReadOnly() {
        let verbs = ["create", "edit", "delete", "send", "reply", "forward", "move", "mark", "complete", "add", "remove", "run"]
        for tool in MCPToolRegistry.tools where verbs.contains(where: { tool.name.hasSuffix("_\($0)") }) {
            XCTAssertNotEqual(tool.effect, .readOnly, tool.name)
        }
    }

    func testVerifyToolsAreReadOnlyAndNeedNoArguments() throws {
        for tool in MCPToolRegistry.tools {
            guard case let .mutating(name?) = tool.effect else { continue }
            let verify = try XCTUnwrap(MCPToolRegistry.tool(named: name), "\(tool.name) verifies with unknown tool \(name)")
            XCTAssertEqual(verify.effect, .readOnly, name)
            XCTAssertEqual(try verify.buildArgs(nil).suffix(2), ["--format", "agent"], name)
        }
    }

    func testToolsListCarriesAnnotations() async throws {
        let request = try JSONDecoder().decode(
            JSONRPCRequest.self, from: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        )
        let response = await MCPDispatcher.handle(request, pippinPath: "/usr/bin/true")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(response))) as? [String: Any])
        let tools = try XCTUnwrap((root["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        func annotations(_ name: String) throws -> [String: Bool] {
            try XCTUnwrap(tools.first { $0["name"] as? String == name }?["annotations"] as? [String: Bool], name)
        }
        XCTAssertEqual(try annotations("mail_list"), ["readOnlyHint": true, "destructiveHint": false])
        XCTAssertEqual(try annotations("mail_send"), ["readOnlyHint": false, "destructiveHint": true])
    }

    // MARK: - Timeout meaning

    private func timedOutError(effect: MCPTool.Effect?) async throws -> [String: Any] {
        let verify = MCPTool(
            name: "things_list", effect: .readOnly, description: "", inputSchema: Schema.empty,
            buildArgs: { _ in ["things", "list", "--format", "agent"] }
        )
        let slow = MCPTool(
            name: "slow_tool", effect: effect, description: "", inputSchema: Schema.empty, buildArgs: { _ in ["10"] }
        )
        let request = try JSONDecoder().decode(
            JSONRPCRequest.self,
            from: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow_tool","arguments":{}}}"#.utf8)
        )
        let response = await MCPDispatcher.handle(
            request, pippinPath: "/bin/sleep", tools: [slow, verify], childTimeoutSeconds: 1
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(response))) as? [String: Any])
        let result = try XCTUnwrap(root["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["error"] as? [String: Any])
    }

    func testTimeoutOnMutatingToolIsOutcomeUnknownAndNotRetryable() async throws {
        let error = try await timedOutError(effect: .mutating(verifyWith: "things_list"))
        XCTAssertEqual(error["code"] as? String, "outcome_unknown")
        let step = try XCTUnwrap(error["next_step"] as? [String: Any])
        XCTAssertEqual(step["retryable"] as? Bool, false)
        XCTAssertNil(step["retry_after_seconds"])
        let call = try XCTUnwrap(step["next_call"] as? [String: Any])
        XCTAssertEqual(call["tool"] as? String, "things_list")
        XCTAssertEqual(call["argv"] as? [String], ["things", "list"])
        XCTAssertTrue((error["message"] as? String ?? "").contains("may or may not"))
    }

    func testTimeoutOnUnclassifiedToolFailsClosedAsOutcomeUnknown() async throws {
        let error = try await timedOutError(effect: nil)
        XCTAssertEqual(error["code"] as? String, "outcome_unknown")
        XCTAssertEqual((error["next_step"] as? [String: Any])?["retryable"] as? Bool, false)
    }

    func testTimeoutOnReadOnlyToolStaysRetryable() async throws {
        let error = try await timedOutError(effect: .readOnly)
        XCTAssertEqual(error["code"] as? String, "child_timed_out")
        XCTAssertEqual((error["next_step"] as? [String: Any])?["retryable"] as? Bool, true)
    }

    // MARK: - Process group

    func testTimeoutKillsGrandchildrenToo() throws {
        let pidFile = NSTemporaryDirectory() + "pippin-grandchild-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        // The grandchild keeps none of our pipes, so only the group kill can end it.
        let script = "sleep 300 >/dev/null 2>&1 & echo $! > '\(pidFile)'; wait"
        XCTAssertThrowsError(
            try MCPServerRuntime.runChild(argv: ["-c", script], pippinPath: "/bin/sh", timeoutSeconds: 1, ownProcessGroup: true)
        ) { error in
            guard case MCPServerRuntimeError.childTimedOut = error else { return XCTFail("expected childTimedOut, got \(error)") }
        }
        let text = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let grandchild = try XCTUnwrap(Int32(text))
        defer { kill(grandchild, SIGKILL) }

        // A killed orphan is a zombie until launchd reaps it, so allow a moment.
        let deadline = Date().addingTimeInterval(3)
        while kill(grandchild, 0) == 0, Date() < deadline {
            usleep(50000)
        }
        XCTAssertEqual(kill(grandchild, 0), -1, "grandchild \(grandchild) survived the timeout")
        XCTAssertEqual(errno, ESRCH)
    }

    func testOwnProcessGroupChildStillReturnsOutputAndExitCode() throws {
        let result = try MCPServerRuntime.runChild(
            argv: ["-c", "echo out; echo err >&2; exit 3"], pippinPath: "/bin/sh", timeoutSeconds: 10, ownProcessGroup: true
        )
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err\n")
    }

    func testMissingBinaryIsALaunchFailure() {
        XCTAssertThrowsError(try MCPServerRuntime.runChild(argv: [], pippinPath: "/nonexistent/pippin")) { error in
            guard case MCPServerRuntimeError.processLaunchFailed = error else {
                return XCTFail("expected processLaunchFailed, got \(error)")
            }
        }
    }
}
