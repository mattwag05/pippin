@testable import PippinLib
import XCTest

final class MessagesSenderTests: XCTestCase {
    func testPHIBodyReachesRunnerAfterCommandLayerCheck() throws {
        // PHI filtering is enforced at the command layer (Send.run), not here.
        // MessagesSender.send() forwards the body to the runner unconditionally.
        nonisolated(unsafe) var capturedBody = ""
        let runner: @Sendable (String, Int) throws -> String = { script, _ in
            capturedBody = script
            return "ok"
        }
        let result = try MessagesSender.send(
            to: "+15551234567",
            body: "card: 4111 1111 1111 1111",
            runner: runner
        )
        XCTAssertTrue(result.delivered)
        XCTAssertTrue(capturedBody.contains("4111"))
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
