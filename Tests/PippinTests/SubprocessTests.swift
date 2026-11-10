import Foundation
@testable import PippinLib
import XCTest

/// The shared child-process helper (ARC-5). Uses only /bin and /usr/bin tools.
final class SubprocessTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    private func sh(
        _ script: String, timeout: TimeInterval = 10, environment: [String: String]? = nil,
        discardStderr: Bool = false
    ) throws -> Subprocess.Outcome {
        try Subprocess.run(
            executable: shell, arguments: ["-c", script], environment: environment,
            timeout: timeout, discardStderr: discardStderr
        )
    }

    func testCapturesBothStreamsAndTheExitStatus() throws {
        let outcome = try sh("echo out; echo err >&2; exit 3")
        XCTAssertEqual(outcome.stdoutText, "out")
        XCTAssertEqual(outcome.stderrText, "err")
        XCTAssertEqual(outcome.status, 3)
        XCTAssertFalse(outcome.signaled)
        XCTAssertFalse(outcome.timedOut)
    }

    func testTextIsTrimmedButTheRawBytesAreKept() throws {
        let outcome = try sh("printf '  padded \\n\\n'")
        XCTAssertEqual(outcome.stdoutText, "padded")
        XCTAssertEqual(String(data: outcome.stdout, encoding: .utf8), "  padded \n\n")
    }

    /// Each stream gets well past the 64 KB pipe buffer. Without concurrent
    /// draining the child blocks on the stream nobody is reading.
    func testLargeOutputOnBothStreamsDoesNotDeadlock() throws {
        let outcome = try sh("head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero | tr '\\0' b >&2")
        XCTAssertEqual(outcome.stdout.count, 300_000)
        XCTAssertEqual(outcome.stderr.count, 300_000)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertFalse(outcome.timedOut)
    }

    func testDiscardedStderrIsNotCapturedAndCannotBlockTheChild() throws {
        let outcome = try sh("head -c 300000 /dev/zero | tr '\\0' b >&2; echo done", discardStderr: true)
        XCTAssertEqual(outcome.stdoutText, "done")
        XCTAssertTrue(outcome.stderr.isEmpty)
    }

    func testTheDeadlineKillsTheChildAndIsReportedAsATimeout() throws {
        let started = Date()
        let outcome = try sh("exec sleep 30", timeout: 0.2)
        XCTAssertTrue(outcome.signaled)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.status, SIGTERM)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testAChildThatIgnoresSIGTERMIsKilledTwoSecondsLater() throws {
        let started = Date()
        let outcome = try sh("trap '' TERM; while :; do sleep 1; done", timeout: 0.2)
        XCTAssertTrue(outcome.signaled)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertEqual(outcome.status, SIGKILL)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    /// A signal that did not come from the deadline is a crash, not a timeout:
    /// callers must not report it as retryable.
    func testASignalFromElsewhereIsNotATimeout() throws {
        let outcome = try sh("kill -SEGV $$")
        XCTAssertTrue(outcome.signaled)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.status, SIGSEGV)
    }

    func testTheEnvironmentReplacesTheInheritedOne() throws {
        let outcome = try sh("echo \"$PIPPIN_SUBPROCESS_TEST\"", environment: ["PIPPIN_SUBPROCESS_TEST": "set"])
        XCTAssertEqual(outcome.stdoutText, "set")
    }

    func testAMissingExecutableThrowsInsteadOfReturningAnOutcome() {
        XCTAssertThrowsError(try Subprocess.run(
            executable: URL(fileURLWithPath: "/nonexistent/pippin-no-such-tool"), arguments: [], timeout: 1
        ))
    }
}
