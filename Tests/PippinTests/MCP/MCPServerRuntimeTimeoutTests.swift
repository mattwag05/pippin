@testable import PippinLib
import XCTest

/// Tests for `MCPServerRuntime.runChild`'s hard timeout safety net. Without
/// this, a wedged child (e.g. osascript stuck on an unresponsive Mail.app)
/// would block the JSON-RPC loop forever instead of returning an error.
final class MCPServerRuntimeTimeoutTests: XCTestCase {
    func testRunChildSucceedsForFastChild() throws {
        // /bin/echo prints and exits immediately — confirms the timeout path
        // doesn't fire on healthy children and stdout is captured intact.
        let result = try MCPServerRuntime.runChild(
            argv: ["hello"],
            pippinPath: "/bin/echo",
            timeoutSeconds: 5
        )
        XCTAssertEqual(result.exitCode, 0)
        let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(stdout.contains("hello"), "expected 'hello' in stdout, got: \(stdout)")
    }

    func testRunChildKillsWedgedChildPastTimeout() throws {
        // /bin/sleep 10 with a 1s timeout must terminate within the 2s SIGTERM
        // grace + a small fudge, throwing .childTimedOut.
        let started = Date()
        do {
            _ = try MCPServerRuntime.runChild(
                argv: ["10"],
                pippinPath: "/bin/sleep",
                timeoutSeconds: 1
            )
            XCTFail("expected childTimedOut error")
        } catch let error as MCPServerRuntimeError {
            guard case let .childTimedOut(seconds) = error else {
                XCTFail("expected .childTimedOut, got \(error)")
                return
            }
            XCTAssertEqual(seconds, 1)
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 6, "runChild should return within ~3-4s, elapsed=\(elapsed)")
            // Error message should hint at narrowing the request (matches actual phrasing).
            XCTAssertTrue(
                error.localizedDescription.contains("Narrow the request"),
                "error message should advise narrowing the request: \(error.localizedDescription)"
            )
        }
    }
}
