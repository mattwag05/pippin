@testable import PippinLib
import XCTest

final class MessagesSenderTests: XCTestCase {
    func testPHIBlockedBeforeScriptRuns() {
        nonisolated(unsafe) var ran = false
        let runner: @Sendable (String, Int) throws -> String = { _, _ in
            ran = true
            return "ok"
        }
        XCTAssertThrowsError(
            try MessagesSender.send(
                to: "+15551234567",
                body: "card: 4111 1111 1111 1111",
                runner: runner
            )
        ) { error in
            guard case let MessagesSendError.phiFiltered(cats) = error else {
                return XCTFail("expected phiFiltered, got \(error)")
            }
            XCTAssertTrue(cats.contains("credit_card"))
        }
        XCTAssertFalse(ran, "script must not run when PHI flagged")
    }

    func testCleanBodyInvokesRunner() throws {
        nonisolated(unsafe) var capturedScript = ""
        let runner: @Sendable (String, Int) throws -> String = { script, _ in
            capturedScript = script
            return "ok"
        }
        let result = try MessagesSender.send(
            to: "+15551234567",
            body: "running late, 10 min",
            runner: runner
        )
        XCTAssertTrue(result.delivered)
        XCTAssertTrue(capturedScript.contains("+15551234567"))
        XCTAssertTrue(capturedScript.contains("running late"))
    }

    func testScriptEscapesSingleQuotesAndNewlines() {
        let script = MessagesSender.buildScript(recipient: "alice@example.com", body: "it's a\nmulti-line")
        XCTAssertTrue(script.contains("it\\'s a\\nmulti-line"))
    }

    func testTimeoutMapsToMessagesSendError() {
        let runner: @Sendable (String, Int) throws -> String = { _, _ in
            throw ScriptRunnerError.timeout
        }
        XCTAssertThrowsError(
            try MessagesSender.send(to: "+15551234567", body: "hi", runner: runner)
        ) { error in
            guard case MessagesSendError.timeout = error else {
                return XCTFail("expected timeout, got \(error)")
            }
        }
    }
}
