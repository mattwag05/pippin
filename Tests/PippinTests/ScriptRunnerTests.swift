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

    // MARK: - Timeout with appName: launcher is invoked once and retry runs

    func testTimeoutWithAppNameInvokesLauncherAndRetries() {
        let script = "delay(10); 'never'"
        nonisolated(unsafe) var launchCalls: [String] = []
        let launcher: ScriptRunner.AppLauncher = { name in
            launchCalls.append(name)
        }

        XCTAssertThrowsError(
            try ScriptRunner.run(script, timeoutSeconds: 2, appName: "TestApp", launcher: launcher)
        ) { err in
            guard case ScriptRunnerError.timeout = err else {
                XCTFail("Expected .timeout after retry, got \(err)")
                return
            }
        }

        XCTAssertEqual(launchCalls, ["TestApp"], "Launcher should be called exactly once for the retry")
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
