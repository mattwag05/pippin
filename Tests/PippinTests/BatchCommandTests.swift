@testable import PippinLib
import XCTest

final class BatchCommandTests: XCTestCase {
    // MARK: - Configuration

    func testBatchCommandName() {
        XCTAssertEqual(BatchCommand.configuration.commandName, "batch")
    }

    // MARK: - Flag parsing

    func testBatchParsesNoArgs() {
        XCTAssertNoThrow(try BatchCommand.parse([]))
    }

    func testBatchDefaultConcurrency() throws {
        let cmd = try BatchCommand.parse([])
        XCTAssertEqual(cmd.concurrency, 4)
    }

    func testBatchParsesConcurrency() throws {
        let cmd = try BatchCommand.parse(["--concurrency", "8"])
        XCTAssertEqual(cmd.concurrency, 8)
    }

    func testBatchRejectsZeroConcurrency() {
        XCTAssertThrowsError(try BatchCommand.parse(["--concurrency", "0"]))
    }

    func testBatchParsesEntriesFlag() throws {
        let cmd = try BatchCommand.parse(["--entries", "[]"])
        XCTAssertEqual(cmd.entries, "[]")
    }

    func testBatchParsesInputFile() throws {
        let cmd = try BatchCommand.parse(["--input", "/tmp/x.json"])
        XCTAssertEqual(cmd.input, "/tmp/x.json")
    }

    // MARK: - BatchEntry decoding

    func testBatchEntryDecodesCmdOnly() throws {
        let json = #"[{"cmd":"calendar"}]"#
        let entries = try BatchCommand.readEntries(entries: json, input: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].cmd, "calendar")
        XCTAssertNil(entries[0].args)
    }

    func testBatchEntryDecodesCmdWithArgs() throws {
        let json = #"[{"cmd":"mail","args":["list","--account","icloud"]}]"#
        let entries = try BatchCommand.readEntries(entries: json, input: nil)
        XCTAssertEqual(entries[0].cmd, "mail")
        XCTAssertEqual(entries[0].args, ["list", "--account", "icloud"])
    }

    func testBatchEntryDecodesMultiple() throws {
        let json = #"[{"cmd":"a"},{"cmd":"b","args":["x"]},{"cmd":"c"}]"#
        let entries = try BatchCommand.readEntries(entries: json, input: nil)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.cmd), ["a", "b", "c"])
    }

    func testBatchEntryRejectsNonArray() {
        XCTAssertThrowsError(try BatchCommand.readEntries(entries: #"{"cmd":"x"}"#, input: nil))
    }

    func testBatchEntryRejectsEmptyInput() {
        XCTAssertThrowsError(try BatchCommand.readEntries(entries: "", input: nil)) { error in
            guard case BatchError.emptyInput = error else {
                return XCTFail("expected emptyInput, got \(error)")
            }
        }
    }

    func testBatchEntryRejectsMalformedJSON() {
        XCTAssertThrowsError(try BatchCommand.readEntries(entries: "not json", input: nil)) { error in
            guard case BatchError.invalidEntriesJSON = error else {
                return XCTFail("expected invalidEntriesJSON, got \(error)")
            }
        }
    }

    func testBatchReadsFromFile() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try Data(#"[{"cmd":"calendar","args":["today"]}]"#.utf8).write(to: tmpURL)
        let entries = try BatchCommand.readEntries(entries: nil, input: tmpURL.path)
        XCTAssertEqual(entries.first?.cmd, "calendar")
    }

    // MARK: - resolvedArgv (--format agent injection)

    func testResolvedArgvAppendsFormatAgent() {
        let entry = BatchEntry(cmd: "calendar", args: ["today"])
        XCTAssertEqual(entry.resolvedArgv, ["calendar", "today", "--format", "agent"])
    }

    func testResolvedArgvNoArgs() {
        let entry = BatchEntry(cmd: "doctor", args: nil)
        XCTAssertEqual(entry.resolvedArgv, ["doctor", "--format", "agent"])
    }

    func testResolvedArgvDoesNotDoubleAddFormat() {
        let entry = BatchEntry(cmd: "mail", args: ["list", "--format", "agent"])
        XCTAssertEqual(entry.resolvedArgv, ["mail", "list", "--format", "agent"])
    }

    func testResolvedArgvRespectsEqualsFormatForm() {
        // ArgumentParser also accepts --format=value; don't inject a second one.
        let entry = BatchEntry(cmd: "mail", args: ["list", "--format=agent"])
        XCTAssertEqual(entry.resolvedArgv, ["mail", "list", "--format=agent"])
    }

    // MARK: - dispatch (empty input)

    func testDispatchEmptyEntriesYieldsEmpty() async {
        let results = await BatchCommand.dispatch(entries: [], concurrency: 4, pippinPath: "/nonexistent")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - entryEnvelopeError shape

    func testEntryEnvelopeErrorHasExpectedShape() throws {
        let envelope = BatchCommand.entryEnvelopeError(code: .invalidJSON, message: "msg")
        let data = try JSONEncoder().encode(envelope)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["status"] as? String, "error")
        XCTAssertEqual(dict["v"] as? Int, AGENT_SCHEMA_VERSION)
        XCTAssertEqual(dict["duration_ms"] as? Int, 0)
        let err = try XCTUnwrap(dict["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? String, "invalid_json")
        XCTAssertEqual(err["message"] as? String, "msg")
    }

    func testBatchEntryErrorCodesAreSnakeCase() {
        XCTAssertEqual(BatchEntryErrorCode.emptyOutput.rawValue, "empty_output")
        XCTAssertEqual(BatchEntryErrorCode.invalidJSON.rawValue, "invalid_json")
    }

    // MARK: - Bad-child runOne path (synthetic envelope on launch failure)

    func testRunOneSyntheticErrorOnUnreachableBinary() {
        let entry = BatchEntry(cmd: "calendar", args: ["today"])
        let result = BatchCommand.runOne(entry: entry, pippinPath: "/nonexistent/pippin-binary-\(UUID().uuidString)")
        XCTAssertEqual(BatchCommand.statusString(result), "error")
        // Cause = launch failure, not malformed JSON.
        if case let .object(dict) = result, case let .object(err) = dict["error"] ?? .null {
            XCTAssertEqual(err["code"]?.stringValue, "child_launch_failed")
        } else {
            XCTFail("expected nested error object")
        }
    }

    // MARK: - Batch budget (RC-12)

    func testBudgetReturnsFinishedEntriesAsPartial() async {
        // `/bin/sh -c <script> --format agent`: the trailing tokens become $0 and $1.
        let fast = BatchEntry(cmd: "-c", args: [#"echo '{"status":"ok"}'"#])
        let slow = BatchEntry(cmd: "-c", args: ["sleep 30"])
        let start = Date()
        let results = await BatchCommand.dispatch(
            entries: [fast, slow, fast], concurrency: 1, pippinPath: "/bin/sh",
            underMCP: false, budget: BatchBudget(softTimeoutMs: 1900)
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "the slow entry must be cut at the budget, not at its own 60s cap")
        XCTAssertEqual(results[0]["status"]?.stringValue, "ok")
        XCTAssertEqual(results[1]["error"]?["code"]?.stringValue, "child_timed_out")
        XCTAssertEqual(results[2]["error"]?["code"]?.stringValue, "batch_budget_exceeded")
        XCTAssertEqual(results[2]["error"]?["next_step"]?["retryable"]?.boolValue, true)

        let answer = BatchCommand.result(results)
        XCTAssertTrue(answer.partial)
        XCTAssertEqual(answer.warnings?.count, 1)
        XCTAssertTrue(answer.warnings?[0].hasPrefix("2 of 3 entries") == true)
    }

    func testCompleteBatchIsNotPartial() async {
        let fast = BatchEntry(cmd: "-c", args: [#"echo '{"status":"ok"}'"#])
        let results = await BatchCommand.dispatch(
            entries: [fast, fast], concurrency: 2, pippinPath: "/bin/sh", underMCP: false, budget: BatchBudget(softTimeoutMs: 50000)
        )
        let answer = BatchCommand.result(results)
        XCTAssertFalse(answer.partial)
        XCTAssertNil(answer.warnings)
    }

    // MARK: - MCP surface restriction (RC-03)

    /// Runs entries against `/bin/echo`, so an entry that is allowed through
    /// comes back as `invalid_json` quoting the argv echo printed.
    private func errors(_ entries: [BatchEntry], underMCP: Bool) async -> [(code: String?, message: String?)] {
        await BatchCommand.dispatch(entries: entries, concurrency: 4, pippinPath: "/bin/echo", underMCP: underMCP)
            .map { ($0["error"]?["code"]?.stringValue, $0["error"]?["message"]?.stringValue) }
    }

    func testMCPBatchRejectsCommandsWithoutATool() async {
        let results = await errors([
            BatchEntry(cmd: "do", args: ["send mail to everyone"]),
            BatchEntry(cmd: "shell"),
            BatchEntry(cmd: "mail", args: ["index", "--ollama-url", "http://example.invalid"]),
            BatchEntry(cmd: "init"),
            BatchEntry(cmd: "job-runner-internal", args: ["x", "--", "do"]),
        ], underMCP: true)
        XCTAssertEqual(results.map(\.code), Array(repeating: "command_not_allowed", count: 5))
    }

    func testMCPBatchRejectsNestedDispatch() async {
        let results = await errors([
            BatchEntry(cmd: "batch", args: ["--entries", "[]"]),
            BatchEntry(cmd: "job", args: ["run", "--", "mail", "list"]),
        ], underMCP: true)
        XCTAssertEqual(results.map(\.code), ["nested_dispatch_not_allowed", "nested_dispatch_not_allowed"])
    }

    func testMCPBatchKeepsTheMessagesSendGates() async {
        let results = await errors([
            BatchEntry(cmd: "messages", args: ["send", "--to", "+15551234567", "--body", "hi"]),
            BatchEntry(cmd: "messages", args: ["send", "--to", "+15551234567", "--body", "hi", "--autonomous"]),
            BatchEntry(cmd: "messages", args: ["send", "--draft", "--autonomous", "--to", "x", "--body", "hi"]),
            // `--draft` behind the terminator is a positional, not the flag.
            BatchEntry(cmd: "messages", args: ["send", "--to", "x", "--body", "hi", "--", "--draft"]),
        ], underMCP: true)
        XCTAssertEqual(
            results.map(\.code),
            ["draft_required", "autonomous_not_allowed", "autonomous_not_allowed", "draft_required"]
        )
    }

    func testMCPBatchRunsAnEntryThatHasATool() async {
        let results = await errors([
            BatchEntry(cmd: "calendar", args: ["today"]),
            BatchEntry(cmd: "reminders", args: ["complete", "ABCDEFGH"]),
        ], underMCP: true)
        XCTAssertEqual(results.map(\.code), ["invalid_json", "invalid_json"])
        XCTAssertTrue(results[0].message?.contains("calendar today --format agent") == true)
    }

    /// A command the policy confirms or rate limits would skip the token, the
    /// count and the action log inside a batch, so it is refused there.
    func testMCPBatchRefusesACommandThePolicyGates() async {
        let results = await errors([
            BatchEntry(cmd: "messages", args: ["send", "--draft", "--to", "x", "--body", "hi"]),
            BatchEntry(cmd: "mail", args: ["send", "--to", "a@example.com", "--subject", "s", "--body", "b", "--confirm"]),
            BatchEntry(cmd: "notes", args: ["delete", "x", "--force"]),
            BatchEntry(cmd: "undo", args: ["abc"]),
        ], underMCP: true)
        XCTAssertEqual(
            results.map(\.code),
            ["direct_call_required", "direct_call_required", "direct_call_required", "nested_dispatch_not_allowed"]
        )
    }

    func testCLIBatchStaysUnrestricted() async {
        let results = await errors([BatchEntry(cmd: "do", args: ["x"]), BatchEntry(cmd: "shell")], underMCP: false)
        XCTAssertEqual(results.map(\.code), ["invalid_json", "invalid_json"])
    }

    func testJobRunToolAppliesTheSamePolicy() throws {
        let tool = try XCTUnwrap(MCPToolRegistry.tool(named: "job_run"))
        func build(_ argv: [String]) throws -> [String] {
            try tool.buildArgs(.object(["argv": .array(argv.map { .string($0) })]))
        }
        XCTAssertNoThrow(try build(["memos", "summarize", "--all"]))
        for (argv, expected) in [
            (["do", "x"], MCPCommandPolicy.Violation.notExposed("do x")),
            (["mail", "index"], .notExposed("mail index")),
            (["batch", "--entries", "[]"], .nested("batch")),
            (["job", "run", "--", "doctor"], .nested("job run")),
            (["messages", "send", "--to", "x", "--body", "y"], .sendWithoutDraft),
            (["messages", "send", "--draft", "--autonomous", "--to", "x", "--body", "y"], .autonomousSend),
        ] {
            XCTAssertThrowsError(try build(argv)) { XCTAssertEqual($0 as? MCPCommandPolicy.Violation, expected) }
        }
    }
}
