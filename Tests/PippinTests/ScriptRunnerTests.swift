@testable import PippinLib
import XCTest

/// Tests for the shared osascript runner. Uses real `/usr/bin/osascript`
/// so we exercise the actual SIGTERM path for timeouts.
final class ScriptRunnerTests: XCTestCase {
    // MARK: - Success path

    func testSimpleScriptReturnsStdout() throws {
        let out = try ScriptRunner.run("'hello from JXA'", timeoutSeconds: 10)
        XCTAssertEqual(out, "hello from JXA")
    }

    // MARK: - Timeout without appName: single timeout, no retry

    func testTimeoutWithoutAppNameThrowsImmediately() {
        // Script sleeps ~10s via JXA — guaranteed to exceed the 2s timeout.
        let script = "delay(10); 'never'"
        let start = Date()
        XCTAssertThrowsError(
            try ScriptRunner.run(script, timeoutSeconds: 2, appName: nil)
        ) { err in
            guard case ScriptRunnerError.timeout = err else {
                XCTFail("Expected .timeout, got \(err)")
                return
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        // Single timeout ≈ 2s + cleanup; retry would roughly double this.
        XCTAssertLessThan(elapsed, 6.0, "Saw \(elapsed)s — looks like a retry happened when it shouldn't")
    }

    // MARK: - One deadline: launch first, run once

    func testAppNotRunningIsLaunchedInsideTheSameDeadline() throws {
        let path = NSTemporaryDirectory() + "pippin-runs-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        nonisolated(unsafe) var launchCalls: [String] = []
        let start = Date()
        XCTAssertThrowsError(
            try ScriptRunner.run(
                appendThenHang(path), timeoutSeconds: 3, appName: "TestApp", idempotent: true,
                launcher: { launchCalls.append($0); Thread.sleep(forTimeInterval: 2) },
                isAppRunning: { _ in false }
            )
        ) { err in
            guard case ScriptRunnerError.timeout = err else { return XCTFail("Expected .timeout, got \(err)") }
        }
        XCTAssertEqual(launchCalls, ["TestApp"])
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").count, 1)
        // 3s in all, launch included. The old relaunch-and-retry took 3 + 2 + 3.
        XCTAssertLessThan(Date().timeIntervalSince(start), 4.5)
    }

    func testRunningAppIsNotRelaunched() throws {
        nonisolated(unsafe) var launchCalls = 0
        let out = try ScriptRunner.run(
            "'ok'", timeoutSeconds: 10, appName: "TestApp", idempotent: true,
            launcher: { _ in launchCalls += 1 }, isAppRunning: { _ in true }
        )
        XCTAssertEqual(out, "ok")
        XCTAssertEqual(launchCalls, 0)
    }

    func testBudgetIsClampedToWhatIsLeftOfTheMCPCommand() {
        XCTAssertEqual(ScriptRunner.budget(requested: 90, underMCP: false, elapsed: 30), 90)
        XCTAssertEqual(ScriptRunner.budget(requested: 90, underMCP: true, elapsed: 0), 55)
        XCTAssertEqual(ScriptRunner.budget(requested: 35, underMCP: true, elapsed: 0), 35)
        // A second script in the same command (reply reads, then sends) gets the remainder.
        XCTAssertEqual(ScriptRunner.budget(requested: 45, underMCP: true, elapsed: 40), 15)
    }

    func testSpentMCPBudgetTimesOutWithoutRunningTheScript() {
        let path = NSTemporaryDirectory() + "pippin-runs-\(UUID().uuidString)"
        XCTAssertLessThanOrEqual(ScriptRunner.budget(requested: 45, underMCP: true, elapsed: 3600), 0)
        // The test runner has been up far less than an hour only in theory, so
        // drive the guard through a zero-second request instead.
        XCTAssertThrowsError(try ScriptRunner.run(appendThenHang(path), timeoutSeconds: 0)) { err in
            guard case ScriptRunnerError.timeout = err else { return XCTFail("Expected .timeout, got \(err)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Writes run once (pippin-z84j)

    /// JXA that appends one line to `path` and then outlives any short timeout.
    private func appendThenHang(_ path: String) -> String {
        """
        var app = Application.currentApplication(); app.includeStandardAdditions = true;
        app.doShellScript("echo run >> '\(path)'"); delay(10); 'never'
        """
    }

    func testTimeoutDoesNotRerunScriptUnlessIdempotent() throws {
        let path = NSTemporaryDirectory() + "pippin-runs-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        nonisolated(unsafe) var launchCalls = 0
        XCTAssertThrowsError(
            try ScriptRunner.run(appendThenHang(path), timeoutSeconds: 3, appName: "TestApp", launcher: { _ in launchCalls += 1 })
        ) { err in
            guard case ScriptRunnerError.timeout = err else { return XCTFail("Expected .timeout, got \(err)") }
        }
        let runs = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(runs, 1, "a script that is not marked idempotent must run exactly once")
        XCTAssertEqual(launchCalls, 0)
    }

    func testSignalDeathNotFromOurTimerIsACrashAndIsNotRetried() {
        let script = """
        ObjC.import('Foundation');
        var app = Application.currentApplication(); app.includeStandardAdditions = true;
        app.doShellScript('kill -KILL ' + $.NSProcessInfo.processInfo.processIdentifier); delay(10); 'never'
        """
        nonisolated(unsafe) var launchCalls = 0
        XCTAssertThrowsError(
            try ScriptRunner.run(script, timeoutSeconds: 30, appName: "TestApp", idempotent: true, launcher: { _ in launchCalls += 1 }, isAppRunning: { _ in true })
        ) { err in
            guard case let ScriptRunnerError.crashed(signal) = err else { return XCTFail("Expected .crashed, got \(err)") }
            XCTAssertEqual(signal, SIGKILL)
        }
        XCTAssertEqual(launchCalls, 0, "a crash must not trigger the relaunch")
    }

    func testOutcomeUnknownIsNotRetryableAndPointsAtAStateCheck() {
        let error = AgentError.from(ScriptRunnerError.outcomeUnknown(app: "Notes")).error
        XCTAssertEqual(error.code, "outcome_unknown")
        XCTAssertFalse(error.nextStep.retryable)
        XCTAssertEqual(error.nextStep.nextCall?.tool, "notes_list")
        XCTAssertEqual(AgentError.from(ScriptRunnerError.crashed(signal: 11)).error.code, "script_crashed")
        XCTAssertFalse(AgentError.from(ScriptRunnerError.crashed(signal: 11)).error.nextStep.retryable)
    }

    // MARK: - Success on first try skips launcher

    func testSuccessSkipsLauncher() throws {
        nonisolated(unsafe) var launchCalls: [String] = []
        let launcher: ScriptRunner.AppLauncher = { name in
            launchCalls.append(name)
        }

        let out = try ScriptRunner.run(
            "'ok'",
            timeoutSeconds: 10,
            appName: "TestApp",
            launcher: launcher
        )
        XCTAssertEqual(out, "ok")
        XCTAssertEqual(launchCalls, [], "Launcher must not fire when the script succeeds")
    }

    // MARK: - Automation pre-check fast-fail (pippin-qjf)

    func testAutomationDeniedFastFailsWithoutRunningScript() {
        // A script that would otherwise block for ~10s. With the injected check
        // returning .deny, run() must throw .automationDenied immediately and
        // never launch osascript.
        let script = "delay(10); 'never'"
        let denyCheck: ScriptRunner.AutomationCheck = { _, _ in .deny }
        let start = Date()
        XCTAssertThrowsError(
            try ScriptRunner.run(
                script,
                timeoutSeconds: 10,
                automationBundleID: "com.apple.mail",
                automationCheck: denyCheck
            )
        ) { err in
            guard case let ScriptRunnerError.automationDenied(bundleID) = err else {
                XCTFail("Expected .automationDenied, got \(err)")
                return
            }
            XCTAssertEqual(bundleID, "com.apple.mail")
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "Fast-fail took \(elapsed)s — the blocking script appears to have run")
    }

    func testAutomationAllowedRunsScript() throws {
        let allowCheck: ScriptRunner.AutomationCheck = { _, _ in .allow }
        let out = try ScriptRunner.run(
            "'ok'",
            timeoutSeconds: 10,
            automationBundleID: "com.apple.mail",
            automationCheck: allowCheck
        )
        XCTAssertEqual(out, "ok")
    }

    func testNoBundleIDSkipsAutomationCheck() throws {
        // With no automationBundleID the check is never consulted, even one that
        // would deny — preserves the existing call-site behavior.
        nonisolated(unsafe) var consulted = false
        let denyCheck: ScriptRunner.AutomationCheck = { _, _ in
            consulted = true
            return .deny
        }
        let out = try ScriptRunner.run("'ok'", timeoutSeconds: 10, automationCheck: denyCheck)
        XCTAssertEqual(out, "ok")
        XCTAssertFalse(consulted, "Automation check must not run when no bundle id is supplied")
    }

    // MARK: - Non-zero exit maps to nonZeroExit

    func testNonZeroExitThrowsNonZeroExit() {
        // JXA script that throws — osascript exits non-zero with stderr.
        let script = "throw new Error('boom')"
        XCTAssertThrowsError(
            try ScriptRunner.run(script, timeoutSeconds: 10)
        ) { err in
            guard case let ScriptRunnerError.nonZeroExit(msg) = err else {
                XCTFail("Expected .nonZeroExit, got \(err)")
                return
            }
            XCTAssertTrue(msg.contains("boom"), "stderr should include 'boom', got: \(msg)")
        }
    }
}
