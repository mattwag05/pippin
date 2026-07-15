@testable import PippinLib
import XCTest

/// Typed mail error mapping (live E2E audit fixes):
/// - JXA not-found script failures → `messageNotFound` → `message_not_found` / exit 3
///   (previously `script_failed` / exit 5 with a raw JXA dump).
/// - Unknown `--account` on list/search/activity → `accountNotFound` →
///   `account_not_found` / exit 3 (previously empty-ok exit 0).
final class MailBridgeErrorMappingTests: XCTestCase {
    // MARK: - mapScriptFailure (JXA path)

    private func assertMessageNotFound(_ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .messageNotFound = MailBridge.mapScriptFailure(msg) else {
            return XCTFail("Expected .messageNotFound for: \(msg)", file: file, line: line)
        }
    }

    private func assertScriptFailed(_ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .scriptFailed = MailBridge.mapScriptFailure(msg) else {
            return XCTFail("Expected .scriptFailed for: \(msg)", file: file, line: line)
        }
    }

    func testReadScriptNotFoundSignatureMaps() {
        // Exact live shape from `mail show "iCloud||INBOX||99999999"`.
        assertMessageNotFound("execution error: Error: Error: Message not found (-2700)")
    }

    func testMarkMoveAttachmentsNotFoundSignaturesMap() {
        assertMessageNotFound("execution error: Error: Error: MAILBRIDGE_ERR_MSG_NOT_FOUND (-2700)")
        assertMessageNotFound("execution error: Error: Error: MAILBRIDGE_ERR_NOT_FOUND (-2700)")
    }

    func testOtherNotFoundResourcesStayScriptFailed() {
        // Destination mailbox (move) and account (send) are different resources.
        assertScriptFailed("execution error: Error: Error: MAILBRIDGE_ERR_TARGET_NOT_FOUND (-2700)")
        assertScriptFailed("execution error: Error: Error: MAILBRIDGE_ERR_ACCT_NOT_FOUND (-2700)")
    }

    func testGenericFailureStaysScriptFailed() {
        assertScriptFailed("execution error: Mail got an error: AppleEvent timed out. (-1712)")
    }

    // MARK: - Agent code / exit code / message shape

    func testMessageNotFoundAgentCodeAndExitCode() {
        let err = MailBridgeError.messageNotFound("raw jxa detail")
        XCTAssertEqual(agentErrorCode(for: err), "message_not_found")
        XCTAssertEqual(PippinExitCode.from(err), 3)
    }

    func testMessageNotFoundDescriptionIsCleanButDebugDetailKeepsRaw() throws {
        let raw = "execution error: Error: Error: Message not found (-2700)"
        let err = MailBridgeError.messageNotFound(raw)
        let desc = try XCTUnwrap(err.errorDescription)
        XCTAssertFalse(desc.contains("Error: Error:"), "doubled JXA prefix leaked: \(desc)")
        XCTAssertFalse(desc.contains("-2700"), "raw JXA code leaked: \(desc)")
        XCTAssertTrue(desc.lowercased().contains("not found"))
        XCTAssertEqual(err.debugDetail, raw)
    }

    func testAccountNotFoundAgentCodeExitCodeAndMessage() throws {
        let err = MailBridgeError.accountNotFound("NoSuch", available: ["iCloud", "Work"])
        XCTAssertEqual(agentErrorCode(for: err), "account_not_found")
        XCTAssertEqual(PippinExitCode.from(err), 3)
        let desc = try XCTUnwrap(err.errorDescription)
        XCTAssertTrue(desc.contains("NoSuch"))
        XCTAssertTrue(desc.contains("iCloud"))
        XCTAssertTrue(desc.contains("Work"))
    }

    // MARK: - ensureKnownAccount (shared gate above the fast-path/JXA fork)

    private let records = [
        MailAccountRecord(name: "iCloud", email: "a@icloud.com", uuid: "AAAA"),
        MailAccountRecord(name: "Work", email: "w@example.com", uuid: "BBBB"),
    ]

    func testKnownAccountPasses() {
        XCTAssertNoThrow(try MailBridge.ensureKnownAccount("iCloud", in: records))
    }

    func testUnknownAccountThrowsWithAvailableNames() {
        XCTAssertThrowsError(try MailBridge.ensureKnownAccount("NoSuch", in: records)) { error in
            guard case let MailBridgeError.accountNotFound(name, available) = error else {
                return XCTFail("Expected .accountNotFound, got \(error)")
            }
            XCTAssertEqual(name, "NoSuch")
            XCTAssertEqual(available, ["iCloud", "Work"])
        }
    }

    func testAccountNamesAreCaseSensitive() {
        // JXA matches acct.name() exactly; the gate must not be looser.
        XCTAssertThrowsError(try MailBridge.ensureKnownAccount("icloud", in: records))
    }

    func testEmptyRecordsSkipsValidation() {
        // Can't enumerate accounts (no cache + Mail not authorized) — let the
        // query proceed to surface its own error rather than false-flagging.
        XCTAssertNoThrow(try MailBridge.ensureKnownAccount("Anything", in: []))
    }
}
