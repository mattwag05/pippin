import Foundation
@testable import PippinLib
import XCTest

/// The controls in `SafetyGate.run`, against the real tool registry and a fake
/// child runner. No test here can reach an app.
final class SafetyGateTests: XCTestCase {
    private var sandbox = SafetySandbox()

    override func setUp() {
        sandbox = SafetySandbox()
    }

    override func tearDown() {
        sandbox.remove()
    }

    private static let secretBody = "The launch code is swordfish-7731"
    private let send: JSONValue = .object([
        "to": .array([.string("a@example.com")]), "subject": .string("Lunch"), "body": .string(SafetyGateTests.secretBody),
    ])

    private func token(_ result: Result<(text: String, isError: Bool), Error>) throws -> String {
        guard case let .confirmationRequired(_, token, _, _, _)? = result.safetyError else {
            XCTFail("expected confirmation_required, got \(result)")
            throw XCTSkip("no token")
        }
        return token
    }

    private func with(_ args: JSONValue, _ extra: [String: JSONValue]) -> JSONValue {
        guard case var .object(dict) = args else { return args }
        dict.merge(extra) { _, new in new }
        return .object(dict)
    }

    // MARK: - Policy at the chokepoint

    func testDenyRefusesBeforeAnythingRuns() async throws {
        try sandbox.writePolicy(#"{"rules": {"mail_*": "deny"}}"#)
        let runner = FakeRunner()
        let result = await sandbox.gate().attempt("mail_move", .object(["messageId": .string("a||b||1"), "to": .string("Archive")]), runner: runner)
        XCTAssertEqual(result.code, "policy_denied")
        XCTAssertEqual(result.safetyError?.nextStep.retryable, false)
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(sandbox.logLines().map(\.outcome), [nil, "denied"])
    }

    func testABrokenPolicyFileFailsClosedForEveryMutatingTool() async throws {
        try sandbox.writePolicy("{ nope")
        let runner = FakeRunner()
        let gate = sandbox.gate()
        for tool in MCPToolRegistry.tools where tool.effect != .readOnly {
            do {
                _ = try await gate.run(tool: tool, arguments: .object([:]), tools: MCPToolRegistry.tools, runArgv: runner.run)
                XCTFail("\(tool.name) ran under a broken policy")
            } catch {
                XCTAssertEqual(agentErrorCode(for: error), "invalid_policy", tool.name)
                XCTAssertTrue(error.localizedDescription.contains(sandbox.policyPath))
            }
        }
        XCTAssertEqual(runner.calls, [])
        // Reads still work: only an explicit deny stops one.
        XCTAssertNoThrow(try gate.checkRead(safetyTool("mail_list"), tools: MCPToolRegistry.tools))
    }

    func testDenyAppliesToReads() throws {
        try sandbox.writePolicy(#"{"rules": {"messages_*": "deny"}}"#)
        XCTAssertThrowsError(try sandbox.gate().checkRead(safetyTool("messages_list"), tools: MCPToolRegistry.tools)) {
            XCTAssertEqual(agentErrorCode(for: $0), "policy_denied")
        }
        XCTAssertNoThrow(try sandbox.gate().checkRead(safetyTool("mail_list"), tools: MCPToolRegistry.tools))
    }

    // MARK: - Confirm tokens

    func testFirstCallPreviewsAndReturnsATokenSecondCallActs() async {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let first = await gate.attempt("mail_send", send, runner: runner)
        XCTAssertEqual(first.code, "confirmation_required")
        guard case let .confirmationRequired(tool, token, summary, expiresAt, preview)? = first.safetyError else { return XCTFail("no token") }
        XCTAssertEqual(tool, "mail_send")
        XCTAssertTrue(summary.contains("mail_send") && summary.contains("a@example.com") && summary.contains("Lunch"), summary)
        XCTAssertFalse(summary.contains(Self.secretBody))
        XCTAssertEqual(expiresAt, ISO8601DateFormatter().string(from: sandbox.clock.now.addingTimeInterval(300)))
        XCTAssertNotNil(preview, "the tool's own dry run is the preview")
        // Only the tool's own preview ran.
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertTrue(runner.calls[0].contains("--dry-run"))
        XCTAssertEqual(runner.actingCalls, [])

        let second = await gate.attempt("mail_send", with(send, ["confirmToken": .string(token)]), runner: runner)
        XCTAssertNil(second.code)
        XCTAssertEqual(runner.actingCalls.count, 1)
        XCTAssertTrue(runner.actingCalls[0].contains("--confirm"))
        XCTAssertFalse(runner.actingCalls[0].contains { $0.contains("confirmToken") || $0.contains(token) })
    }

    func testTokenIsSingleUse() async throws {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let args = try await with(send, ["confirmToken": .string(token(gate.attempt("mail_send", send, runner: runner)))])
        let first = await gate.attempt("mail_send", args, runner: runner)
        XCTAssertNil(first.code)
        let again = await gate.attempt("mail_send", args, runner: runner)
        XCTAssertEqual(again.code, "confirm_token_reused")
        XCTAssertEqual(runner.actingCalls.count, 1)
    }

    func testTokenExpiresAfterFiveMinutes() async throws {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let token = try await token(gate.attempt("mail_send", send, runner: runner))
        sandbox.clock.advance(301)
        let result = await gate.attempt("mail_send", with(send, ["confirmToken": .string(token)]), runner: runner)
        XCTAssertEqual(result.code, "confirm_token_expired")
        XCTAssertEqual(runner.actingCalls, [])
    }

    func testTokenIsBoundToToolAndArguments() async throws {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let token = try await token(gate.attempt("mail_send", send, runner: runner))
        let changed = with(send, ["to": .array([.string("someone-else@example.com")]), "confirmToken": .string(token)])
        let other = await gate.attempt("mail_send", changed, runner: runner)
        XCTAssertEqual(other.code, "confirm_token_mismatch")
        let otherTool = await gate.attempt("notes_delete", .object(["id": .string("x"), "confirmToken": .string(token)]), runner: runner)
        XCTAssertEqual(otherTool.code, "confirm_token_mismatch")
        XCTAssertEqual(runner.actingCalls, [])
        // The mismatch did not spend the token: the right arguments still work.
        let right = await gate.attempt("mail_send", with(send, ["confirmToken": .string(token), "confirm": .bool(true)]), runner: runner)
        XCTAssertNil(right.code)
    }

    func testUnknownTokenAndRestartedServerAreRefused() async throws {
        let runner = FakeRunner()
        let made = await sandbox.gate().attempt("mail_send", with(send, ["confirmToken": .string("not-a-token")]), runner: runner)
        XCTAssertEqual(made.code, "confirm_token_invalid")
        let token = try await token(sandbox.gate().attempt("mail_send", send, runner: runner))
        // A new gate is a restarted server: it has no tokens.
        let restarted = await sandbox.gate().attempt("mail_send", with(send, ["confirmToken": .string(token)]), runner: runner)
        XCTAssertEqual(restarted.code, "confirm_token_invalid")
        XCTAssertEqual(runner.actingCalls, [])
        XCTAssertFalse(FileManager.default.subpaths(atPath: sandbox.root)?.contains { path in
            (try? String(contentsOfFile: sandbox.root + "/" + path, encoding: .utf8))?.contains(token) == true
        } ?? false, "a token must never be written to disk")
    }

    func testDeleteNeedsATokenAndHasNoPreview() async {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let args: JSONValue = .object(["id": .string("x-coredata://note/1"), "confirm": .bool(true)])
        let first = await gate.attempt("notes_delete", args, runner: runner)
        guard case let .confirmationRequired(_, token, _, _, preview)? = first.safetyError else { return XCTFail("no token") }
        XCTAssertNil(preview)
        XCTAssertEqual(runner.calls, [])
        // The token stands in for `confirm: true`.
        let second = await gate.attempt("notes_delete", .object(["id": .string("x-coredata://note/1"), "confirmToken": .string(token)]), runner: runner)
        XCTAssertNil(second.code)
        XCTAssertEqual(runner.actingCalls.count, 1)
        XCTAssertTrue(runner.actingCalls[0].contains("--force"))
    }

    func testAnExplicitDryRunOrConfirmFalseOnlyPreviews() async throws {
        try sandbox.writePolicy(#"{"rules": {"mail_move": "confirm"}}"#)
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let dry = await gate.attempt("mail_move", .object(["messageId": .string("a||b||1"), "to": .string("Archive"), "dryRun": .bool(true)]), runner: runner)
        XCTAssertNil(dry.code)
        let preview = await gate.attempt("mail_send", with(send, ["confirm": .bool(false)]), runner: runner)
        XCTAssertNil(preview.code)
        XCTAssertEqual(runner.actingCalls, [])
        XCTAssertEqual(sandbox.logLines().compactMap(\.outcome), ["dry_run", "dry_run"])
    }

    func testAllowedToolsBehaveAsBefore() async {
        let runner = FakeRunner()
        let result = await sandbox.gate().attempt("mail_mark", .object(["messageId": .string("a||b||1"), "read": .bool(true)]), runner: runner)
        XCTAssertNil(result.code)
        XCTAssertEqual(runner.actingCalls.count, 1)
    }

    // MARK: - Rate limits

    func testRateLimitIsASlidingWindowThatSurvivesARestart() async throws {
        try sandbox.writePolicy(#"{"rules": {"mail_mark": "allow"}, "limits": {"mail_mark": {"max": 2, "per_seconds": 60}}}"#)
        let runner = FakeRunner()
        let args: JSONValue = .object(["messageId": .string("a||b||1"), "read": .bool(true)])
        let first = await sandbox.gate().attempt("mail_mark", args, runner: runner)
        sandbox.clock.advance(20)
        let second = await sandbox.gate().attempt("mail_mark", args, runner: runner)
        XCTAssertNil(first.code)
        XCTAssertNil(second.code)

        // A new gate: the count came from disk, not memory.
        sandbox.clock.advance(10)
        let third = await sandbox.gate().attempt("mail_mark", args, runner: runner)
        XCTAssertEqual(third.code, "rate_limited")
        guard case let .rateLimited(_, limit, retryAfter)? = third.safetyError else { return XCTFail("not rate limited") }
        XCTAssertEqual(limit, .init(max: 2, perSeconds: 60))
        XCTAssertEqual(retryAfter, 30, "the first call ages out 60s after it was made")
        XCTAssertEqual(third.safetyError?.nextStep, .retry(after: 30))
        XCTAssertEqual(runner.actingCalls.count, 2)

        // A dry run is not counted or limited.
        let dry = await sandbox.gate().attempt("mail_mark", with(args, ["dryRun": .bool(true)]), runner: runner)
        XCTAssertNil(dry.code)

        sandbox.clock.advance(31)
        let later = await sandbox.gate().attempt("mail_mark", args, runner: runner)
        XCTAssertNil(later.code)

        let mode = try FileManager.default.attributesOfItem(atPath: sandbox.stateDir + "/rate-limits.json")[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testDefaultSendLimitIsTenPerHour() async throws {
        try sandbox.writePolicy(#"{"rules": {"mail_send": "allow"}}"#)
        let runner = FakeRunner()
        let args = with(send, ["confirm": .bool(true)])
        for _ in 0 ..< 10 {
            let ok = await sandbox.gate().attempt("mail_send", args, runner: runner)
            XCTAssertNil(ok.code)
        }
        let eleventh = await sandbox.gate().attempt("mail_send", args, runner: runner)
        XCTAssertEqual(eleventh.code, "rate_limited")
        XCTAssertEqual(runner.actingCalls.count, 10)
    }

    func testTheRateLimitIsCheckedBeforeATokenIsIssued() async throws {
        try sandbox.writePolicy(#"{"limits": {"mail_send": {"max": 0, "per_seconds": 60}}}"#)
        let result = await sandbox.gate().attempt("mail_send", send, runner: FakeRunner())
        XCTAssertEqual(result.code, "rate_limited")
    }

    // MARK: - Action log

    func testIntentIsWrittenBeforeTheActionAndOutcomeAfter() async throws {
        let sandbox = sandbox
        let runner = FakeRunner { _ in
            // While the action runs, the log already holds its intent and nothing else.
            XCTAssertEqual(sandbox.logLines().map(\.phase), ["intent"])
            return (#"{"v":4,"status":"ok","duration_ms":1,"data":{}}"#, false)
        }
        let result = await sandbox.gate().attempt("mail_mark", .object(["messageId": .string("a||b||1"), "read": .bool(true)]), runner: runner)
        XCTAssertNil(result.code)
        let lines = sandbox.logLines()
        XCTAssertEqual(lines.map(\.phase), ["intent", "outcome"])
        XCTAssertEqual(lines[0].id, lines[1].id)
        XCTAssertEqual(lines[0].tool, "mail_mark")
        XCTAssertEqual(lines[0].rule, "allow")
        XCTAssertEqual(lines[0].args?["messageId"], .string("a||b||1"))
        XCTAssertNotNil(ISO8601DateFormatter().date(from: lines[0].ts))
        XCTAssertEqual(lines[1].outcome, "success")
        XCTAssertNotNil(lines[1].undo, "every outcome says whether it can be undone")
        let mode = try FileManager.default.attributesOfItem(atPath: sandbox.logPath)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testBodiesAndSecretsNeverReachTheLog() async throws {
        let apiKey = "sk-live-9f8e7d6c5b4a" // fake fixture. pragma: allowlist secret
        let runner = FakeRunner()
        let gate = sandbox.gate()
        let sent = try await gate.attempt("mail_send", with(send, ["confirmToken": .string(token(gate.attempt("mail_send", send, runner: runner)))]), runner: runner)
        XCTAssertNil(sent.code)
        _ = await gate.attempt("notes_edit", .object(["id": .string("n1"), "body": .string(Self.secretBody)]), runner: runner)
        _ = await gate.attempt("calendar_edit", .object(["id": .string("e1"), "notes": .string(Self.secretBody)]), runner: runner)
        _ = await gate.attempt("job_run", .object(["argv": .array([
            .string("memos"), .string("summarize"), .string("--api-key=\(apiKey)"), .string("--"), .string(Self.secretBody),
        ])]), runner: runner)
        // An argument the schema does not declare is refused, and still not logged verbatim.
        let unknown = await gate.attempt("mail_mark", .object(["messageId": .string("a||b||1"), "read": .bool(true), "apiKey": .string(apiKey)]), runner: runner)
        XCTAssertEqual(unknown.code, "unexpected_argument")

        let text = sandbox.logText()
        XCTAssertFalse(text.contains(Self.secretBody))
        XCTAssertFalse(text.contains("swordfish"))
        XCTAssertFalse(text.contains(apiKey))
        XCTAssertTrue(text.contains(ArgRedactor.sha256(Self.secretBody)), "a body is logged as its hash")
        XCTAssertTrue(text.contains("a@example.com") && text.contains("Lunch"), "targets stay readable")
        let body = try XCTUnwrap(sandbox.logLines().first { $0.tool == "mail_send" }?.args?["body"])
        XCTAssertEqual(body["length"], .int(Int64(Self.secretBody.count)))
    }

    func testEveryRefusalIsLoggedWithItsOutcome() async throws {
        try sandbox.writePolicy(#"{"rules": {"mail_move": "deny"}, "limits": {"mail_mark": {"max": 0, "per_seconds": 60}}}"#)
        let runner = FakeRunner { argv in
            argv.contains("reminders") ? (#"{"v":4,"status":"error","duration_ms":1,"error":{"code":"reminder_not_found","message":"x","next_step":{"retryable":false}}}"#, true)
                : (#"{"v":4,"status":"ok","duration_ms":1,"data":{}}"#, false)
        }
        let gate = sandbox.gate()
        _ = await gate.attempt("mail_move", .object(["messageId": .string("a||b||1"), "to": .string("X")]), runner: runner)
        _ = await gate.attempt("mail_mark", .object(["messageId": .string("a||b||1"), "read": .bool(true)]), runner: runner)
        _ = await gate.attempt("mail_send", send, runner: runner)
        _ = await gate.attempt("mail_send", with(send, ["confirmToken": .string("bogus")]), runner: runner)
        _ = await gate.attempt("reminders_complete", .object(["id": .string("ABCDEFGH")]), runner: runner)
        _ = await gate.attempt("mail_mark", .object(["read": .bool(true)]), runner: runner)
        let entries = ActionLog(path: sandbox.logPath).entries().reversed()
        XCTAssertEqual(entries.map(\.outcome), ["denied", "rate_limited", "confirmation_required", "refused", "failed", "refused"])
        XCTAssertEqual(entries.map(\.errorCode), [
            "policy_denied", "rate_limited", "confirmation_required", "confirm_token_invalid", "reminder_not_found", "missing_required",
        ])
        XCTAssertTrue(entries.allSatisfy { !$0.undo.supported && $0.undo.reason != nil })
    }

    func testATimeoutIsLoggedAsOutcomeUnknown() async {
        let runner = FakeRunner { _ in throw MCPServerRuntimeError.childTimedOut(seconds: 60) }
        let result = await sandbox.gate().attempt("mail_mark", .object(["messageId": .string("a||b||1"), "read": .bool(true)]), runner: runner)
        XCTAssertEqual(result.code, "outcome_unknown")
        XCTAssertEqual(sandbox.logLines().last?.outcome, "outcome_unknown")
    }

    func testNoIntentLineNoAction() async throws {
        // The state directory is a file, so the log cannot be created.
        try "x".write(toFile: sandbox.stateDir, atomically: true, encoding: .utf8)
        let runner = FakeRunner()
        let result = await sandbox.gate().attempt("mail_mark", .object(["messageId": .string("a||b||1"), "read": .bool(true)]), runner: runner)
        XCTAssertEqual(result.code, "audit_log_unavailable")
        guard case let .auditLogUnavailable(path, _)? = result.safetyError else { return XCTFail("wrong error") }
        XCTAssertEqual(path, sandbox.logPath)
        XCTAssertEqual(runner.calls, [])
    }

    func testLogEntriesMergeFilterAndPage() async throws {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        for index in 0 ..< 3 {
            _ = await gate.attempt("mail_mark", .object(["messageId": .string("a||b||\(index)"), "read": .bool(true)]), runner: runner)
            sandbox.clock.advance(3600)
        }
        _ = await gate.attempt("mail_send", send, runner: runner)
        let entries = ActionLog(path: sandbox.logPath).entries()
        XCTAssertEqual(entries.map(\.tool), ["mail_send", "mail_mark", "mail_mark", "mail_mark"], "newest first")
        XCTAssertEqual(LogCommand.filter(entries, since: nil, tool: "mail_mark").count, 3)
        let since = sandbox.clock.now.addingTimeInterval(-3600 * 2 - 1)
        XCTAssertEqual(LogCommand.filter(entries, since: since, tool: nil).map(\.tool), ["mail_send", "mail_mark", "mail_mark"])
        let page = try Pagination.paginate(all: entries, offset: 0, pageSize: 2, filterHash: "h")
        XCTAssertEqual(page.items.count, 2)
        XCTAssertNotNil(page.nextCursor)
    }

    func testAnIntentWithNoOutcomeReadsAsOutcomeUnknown() throws {
        let log = ActionLog(path: sandbox.logPath)
        try log.append(ActionLogLine(ts: "2026-11-09T00:00:00Z", id: "dead", phase: "intent", tool: "mail_send"))
        XCTAssertEqual(log.entries().map(\.outcome), ["outcome_unknown"])
    }

    // MARK: - Idempotency keys

    func testSameKeyAndArgumentsReplaysWithoutActing() async throws {
        let runner = FakeRunner()
        let args: JSONValue = .object(["messageId": .string("a||b||1"), "read": .bool(true), "idempotencyKey": .string("k-1")])
        let first = try await sandbox.gate().attempt("mail_mark", args, runner: runner).get()
        XCTAssertFalse(first.text.contains("replayed"))
        // A restarted server still knows the key.
        let second = try await sandbox.gate().attempt("mail_mark", args, runner: runner).get()
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.text.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["replayed"] as? Bool, true)
        XCTAssertEqual(envelope["status"] as? String, "ok")
        XCTAssertNotNil(envelope["data"])
        XCTAssertEqual(runner.actingCalls.count, 1)
        XCTAssertFalse(runner.calls.contains { $0.contains { $0.contains("k-1") } }, "the key never reaches the child")

        sandbox.clock.advance(24 * 3600 + 1)
        _ = try await sandbox.gate().attempt("mail_mark", args, runner: runner).get()
        XCTAssertEqual(runner.actingCalls.count, 2, "after 24 hours the key is forgotten")
    }

    func testSameKeyWithDifferentArgumentsIsAnError() async {
        let runner = FakeRunner()
        let gate = sandbox.gate()
        _ = await gate.attempt("mail_mark", .object(["messageId": .string("a||b||1"), "read": .bool(true), "idempotencyKey": .string("k")]), runner: runner)
        let other = await gate.attempt("mail_mark", .object(["messageId": .string("a||b||2"), "read": .bool(true), "idempotencyKey": .string("k")]), runner: runner)
        XCTAssertEqual(other.code, "idempotency_key_conflict")
        let otherTool = await gate.attempt("mail_move", .object(["messageId": .string("a||b||1"), "to": .string("X"), "idempotencyKey": .string("k")]), runner: runner)
        XCTAssertEqual(otherTool.code, "idempotency_key_conflict")
        XCTAssertEqual(runner.actingCalls.count, 1)
    }

    func testAKeyWhoseFirstAttemptIsUnknownIsNotRunAgain() async {
        let args: JSONValue = .object(["messageId": .string("a||b||1"), "read": .bool(true), "idempotencyKey": .string("k")])
        let slow = FakeRunner { _ in throw MCPServerRuntimeError.childTimedOut(seconds: 60) }
        let first = await sandbox.gate().attempt("mail_mark", args, runner: slow)
        XCTAssertEqual(first.code, "outcome_unknown")
        let runner = FakeRunner()
        let second = await sandbox.gate().attempt("mail_mark", args, runner: runner)
        XCTAssertEqual(second.code, "outcome_unknown")
        guard case .priorOutcomeUnknown? = second.safetyError else { return XCTFail("expected the recorded fact, got \(second)") }
        XCTAssertEqual(runner.calls, [])
    }

    func testACleanFailureFreesTheKey() async throws {
        let args: JSONValue = .object(["messageId": .string("a||b||1"), "read": .bool(true), "idempotencyKey": .string("k")])
        let failing = FakeRunner { _ in (#"{"v":4,"status":"error","duration_ms":1,"error":{"code":"message_not_found","message":"x","next_step":{"retryable":false}}}"#, true) }
        let first = try await sandbox.gate().attempt("mail_mark", args, runner: failing).get()
        XCTAssertTrue(first.isError)
        let runner = FakeRunner()
        let second = try await sandbox.gate().attempt("mail_mark", args, runner: runner).get()
        XCTAssertFalse(second.isError)
        XCTAssertEqual(runner.actingCalls.count, 1)
    }

    func testReservedArgumentsMustBeShortStrings() async {
        let bad = await sandbox.gate().attempt("mail_mark", .object(["messageId": .string("a||b||1"), "read": .bool(true), "idempotencyKey": .int(5)]), runner: FakeRunner())
        XCTAssertEqual(bad.code, "invalid_argument")
    }
}
