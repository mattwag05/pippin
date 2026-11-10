@testable import PippinLib
import XCTest

/// Every send attempt leaves an audit trail, whatever its outcome. Nothing here
/// reaches Messages: sends go through an injected sender.
final class MessagesSendAuditTests: XCTestCase {
    private var sandbox: MessagesCommandSandbox!
    private static let recipient = "+15551234567"

    override func setUpWithError() throws {
        sandbox = try MessagesCommandSandbox()
        unsetenv("PIPPIN_AUTONOMOUS_MESSAGES")
    }

    override func tearDown() {
        unsetenv("PIPPIN_AUTONOMOUS_MESSAGES")
        sandbox.tearDown()
    }

    private func outcomes() throws -> [String] {
        try sandbox.auditEntries().map { $0["outcome"] as? String ?? "<none>" }
    }

    /// The log's entries, after checking their outcomes. Throws when the count
    /// is off so a caller can index the result safely.
    private func trail(
        _ expected: [String], file: StaticString = #filePath, line: UInt = #line
    ) throws -> [[String: Any]] {
        let entries = try sandbox.auditEntries()
        XCTAssertEqual(try outcomes(), expected, file: file, line: line)
        return try XCTUnwrap(entries.count == expected.count ? entries : nil, file: file, line: line)
    }

    private func errorCode(_ entry: [String: Any]) -> String? {
        (entry["params"] as? [String: String])?["error"]
    }

    func testGateRefusalIsAudited() async throws {
        var cmd = try MessagesCommand.Send.parse(["--to", Self.recipient, "--body", "hi", "--autonomous"])
        do {
            _ = try await cmd.execute()
            XCTFail("expected autonomous_not_authorized")
        } catch {
            XCTAssertEqual(agentErrorCode(for: error), "autonomous_not_authorized")
        }
        let entries = try sandbox.auditEntries()
        XCTAssertEqual(try outcomes(), ["refused"])
        XCTAssertEqual(entries.first?["recipient"] as? String, Self.recipient)
        XCTAssertEqual(entries.first?["sent"] as? Bool, false)
        XCTAssertEqual(entries.first.flatMap(errorCode), "autonomous_not_authorized")
    }

    // MARK: - performSend with an injected sender

    private static let delivered = MessagesSender.SendResult(delivered: true, detail: "ok")

    /// Runs an autonomous send with the gate open and `sender` standing in for Messages.
    private func send(
        body: String = "hi",
        sender: (String, String) throws -> MessagesSender.SendResult
    ) throws -> (payload: MessagesSendResult, warnings: [String]) {
        try MessagesCommand.performSend(
            to: Self.recipient, body: body, mode: .autonomous, gate: { _ in }, sender: sender
        )
    }

    private func assertSendFails(
        code: String, _ run: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try run(), file: file, line: line) { error in
            XCTAssertEqual(agentErrorCode(for: error), code, "\(error)", file: file, line: line)
        }
    }

    func testRecipientOutsideAllowlistIsRefusedAndAudited() throws {
        setenv("PIPPIN_AUTONOMOUS_MESSAGES", "1", 1)
        try sandbox.writeConfig(#"{"messages":{"autonomousAllowlist":["+15550000000"]}}"#)
        assertSendFails(code: "recipient_not_allowed") {
            // The real gate, default argument.
            _ = try MessagesCommand.performSend(to: Self.recipient, body: "hi", mode: .autonomous) { _, _ in
                XCTFail("sender reached past the gate")
                return Self.delivered
            }
        }
        XCTAssertEqual(try outcomes(), ["refused"])
        XCTAssertEqual(try sandbox.auditEntries().first.flatMap(errorCode), "recipient_not_allowed")
    }

    func testSuccessfulSendWritesAttemptBeforeSendingThenSuccess() throws {
        var seenBeforeSend: [String] = []
        let result = try send { to, body in
            XCTAssertEqual(to, Self.recipient)
            XCTAssertEqual(body, "hi")
            seenBeforeSend = (try? self.outcomes()) ?? []
            return Self.delivered
        }
        XCTAssertEqual(seenBeforeSend, ["attempt"], "the attempt line is on disk before Messages is asked to send")
        XCTAssertTrue(result.payload.delivered)
        XCTAssertEqual(result.warnings, [])
        let entries = try trail(["attempt", "success"])
        XCTAssertNil(entries[0]["sent"], "an attempt does not claim delivery")
        XCTAssertEqual(entries[1]["sent"] as? Bool, true)
    }

    func testTimedOutSendIsAuditedAsOutcomeUnknown() throws {
        assertSendFails(code: "send_outcome_unknown") {
            _ = try send { _, _ in throw MessagesSendError.timeout }
        }
        let entries = try trail(["attempt", "outcome_unknown"])
        XCTAssertNil(entries[1]["sent"], "delivery is unknown, so neither true nor false")
        XCTAssertEqual(errorCode(entries[1]), "send_outcome_unknown")
        XCTAssertEqual(entries[1]["recipient"] as? String, Self.recipient)
    }

    func testFailedSendIsAudited() throws {
        assertSendFails(code: "script_failed") {
            _ = try send { _, _ in throw MessagesSendError.scriptFailed("boom") }
        }
        let entries = try trail(["attempt", "failed"])
        XCTAssertEqual(entries[1]["sent"] as? Bool, false)
        XCTAssertEqual(errorCode(entries[1]), "script_failed")
    }

    func testNothingIsSentWhenTheAttemptCannotBeLogged() throws {
        // A regular file where the log's folder should be: the log cannot be created.
        let blocked = sandbox.dbPath + "/audit.jsonl"
        setenv("PIPPIN_MESSAGES_AUDIT_PATH", blocked, 1)
        var sends = 0
        XCTAssertThrowsError(try send { _, _ in
            sends += 1
            return Self.delivered
        }) { error in
            XCTAssertEqual(agentErrorCode(for: error), "audit_log_unavailable")
            let action = (error as? RemediableError)?.nextStep.humanAction ?? ""
            XCTAssertTrue(action.contains(blocked), "next_step names the log: \(action)")
        }
        XCTAssertEqual(sends, 0)
    }

    func testGuardrailRefusalIsAuditedAndNeverSends() throws {
        assertSendFails(code: "phi_filtered") {
            _ = try send(body: "password: hunter2") { _, _ in
                XCTFail("sender reached past the guardrail")
                return Self.delivered
            }
        }
        XCTAssertEqual(try outcomes(), ["refused"])
        XCTAssertEqual(try sandbox.auditEntries().first?["overrides"] as? [String], ["password_mention"])
    }

    func testDraftIsAuditedAndNeverSends() throws {
        let result = try MessagesCommand.performSend(to: Self.recipient, body: "hi", mode: .draft) { _, _ in
            XCTFail("a draft must not send")
            return Self.delivered
        }
        XCTAssertFalse(result.payload.delivered)
        XCTAssertEqual(try outcomes(), ["draft"])
        XCTAssertEqual(try sandbox.auditEntries().first?["sent"] as? Bool, false)
    }

    func testAuditLogStoresTheHashNeverTheBody() throws {
        let body = "meet me at the usual place"
        _ = try send(body: body) { _, _ in Self.delivered }
        let log = try String(contentsOfFile: sandbox.auditPath, encoding: .utf8)
        XCTAssertFalse(log.contains(body))
        XCTAssertEqual(try sandbox.auditEntries().first?["body_hash"] as? String, MessagesAuditLog.hash(body: body))
    }

    // MARK: - Log file

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    func testAuditLogIsPrivate() throws {
        XCTAssertTrue(MessagesAuditLog.record(operation: "list"))
        XCTAssertEqual(try mode(sandbox.auditPath), 0o600, "new log")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sandbox.auditPath)
        XCTAssertTrue(MessagesAuditLog.record(operation: "list"))
        XCTAssertEqual(try mode(sandbox.auditPath), 0o600, "a log left 0644 by an earlier version")
        XCTAssertEqual(try sandbox.auditEntries().count, 2, "appends, never truncates")
    }

    func testRecordReportsAWriteFailure() {
        XCTAssertFalse(MessagesAuditLog.record(operation: "list", path: sandbox.dbPath + "/audit.jsonl"))
    }
}
