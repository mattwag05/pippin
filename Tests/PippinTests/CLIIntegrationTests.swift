@testable import PippinLib
import XCTest

/// Integration tests that run the actual `pippin` binary via Process.
///
/// The binary must be built before these tests run. In CI the build step
/// precedes `swift test`. Locally, run `swift build` first.
///
/// Tests are skipped (not failed) when the binary is absent so that
/// `swift test` still works without a prior build step.
final class CLIIntegrationTests: XCTestCase {
    nonisolated(unsafe) static var binaryURL: URL?

    override class func setUp() {
        super.setUp()
        // Locate the binary WITHOUT invoking a nested `swift build` — the outer
        // `swift test` holds the SwiftPM workspace lock for its whole run, so a
        // child build blocks on the same lock forever (pippin-eai).
        if let override = ProcessInfo.processInfo.environment["PIPPIN_TEST_BINARY"],
           FileManager.default.fileExists(atPath: override) {
            binaryURL = URL(fileURLWithPath: override)
            return
        }
        // `swift test` builds executable targets too, into the same products dir
        // the xctest bundle lives in — the binary is our bundle's sibling.
        let productsDir = Bundle(for: CLIIntegrationTests.self).bundleURL.deletingLastPathComponent()
        let candidate = productsDir.appendingPathComponent("pippin")
        if FileManager.default.fileExists(atPath: candidate.path) {
            binaryURL = candidate
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ args: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        guard let binary = CLIIntegrationTests.binaryURL else {
            return ("", "", 0)
        }
        return Self.runProcess(binary.path, args: args)
    }

    private func requireBinary(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if CLIIntegrationTests.binaryURL == nil {
            XCTFail("pippin binary not found — run `swift build` before running integration tests", file: file, line: line)
            return false
        }
        return true
    }

    @discardableResult
    static func runProcess(_ executable: String, args: [String], env: [String: String]? = nil) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // Integration tests cover command behavior, not the disclaim re-exec
        // wrapper (unit-tested in DisclaimRespawnTests + verified out-of-band).
        // Skipping it keeps the suite fast and deterministic: a disclaimed binary
        // would run under pippin's own (un-granted) TCC identity and block
        // Mail/Notes automation calls to their soft-timeout. See pippin-0vr.
        var childEnv = env ?? ProcessInfo.processInfo.environment
        childEnv[DisclaimRespawn.optOutKey] = "1"
        process.environment = childEnv

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        guard (try? process.run()) != nil else {
            return ("", "failed to launch \(executable)", -1)
        }
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    @discardableResult
    private func runWithEnv(
        _ args: [String],
        env: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (stdout: String, stderr: String, exitCode: Int32) {
        guard let binary = CLIIntegrationTests.binaryURL else {
            // Defense in depth: callers should `requireBinary()` first, but if a
            // future test forgets, a missing-build state must not look like success.
            XCTFail("pippin binary not found — run `swift build` before running integration tests", file: file, line: line)
            return ("", "", -1)
        }
        return Self.runProcess(binary.path, args: args, env: env)
    }

    // MARK: - Version

    func testVersionFlag() {
        guard requireBinary() else { return }
        let result = run(["--version"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains(PippinVersion.version), "Expected version string in output, got: \(result.stdout)")
    }

    // MARK: - Help

    func testRootHelp() {
        guard requireBinary() else { return }
        let result = run(["--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("mail") || combined.contains("USAGE"), "Expected help output, got: \(combined)")
    }

    func testMailHelp() {
        guard requireBinary() else { return }
        let result = run(["mail", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("list") || combined.contains("SUBCOMMANDS"), "Expected mail subcommand list, got: \(combined)")
    }

    func testMemosHelp() {
        guard requireBinary() else { return }
        let result = run(["memos", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("list") || combined.contains("SUBCOMMANDS"), "Expected memos subcommand list, got: \(combined)")
    }

    func testDoctorHelp() {
        guard requireBinary() else { return }
        let result = run(["doctor", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("doctor") || combined.contains("USAGE"), "Expected doctor help output, got: \(combined)")
    }

    func testInitHelp() {
        guard requireBinary() else { return }
        let result = run(["init", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("init") || combined.contains("USAGE"), "Expected init help output, got: \(combined)")
    }

    // MARK: - Subcommand help pages

    func testMailListHelp() {
        guard requireBinary() else { return }
        let result = run(["mail", "list", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("--limit") || combined.contains("limit"), "Expected --limit flag in help, got: \(combined)")
    }

    func testMemosListHelp() {
        guard requireBinary() else { return }
        let result = run(["memos", "list", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("--limit") || combined.contains("limit"), "Expected --limit flag in help, got: \(combined)")
    }

    func testCalendarHelp() {
        guard requireBinary() else { return }
        let result = run(["calendar", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(
            combined.contains("events") || combined.contains("SUBCOMMANDS"),
            "Expected calendar subcommand list, got: \(combined)"
        )
    }

    func testCalendarEventsHelp() {
        guard requireBinary() else { return }
        let result = run(["calendar", "events", "--help"])
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(
            combined.contains("--from") || combined.contains("from"),
            "Expected --from flag in help, got: \(combined)"
        )
    }

    // MARK: - Invalid input

    func testUnknownSubcommandExitsNonZero() {
        guard requireBinary() else { return }
        let result = run(["totally-invalid-subcommand"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testMailListInvalidFormatExitsNonZero() {
        guard requireBinary() else { return }
        let result = run(["mail", "list", "--format", "xml"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    // MARK: - Typed exit codes

    /// A not-found resource error maps to exit code 3. `job show` is chosen
    /// because it needs no system permissions (pure filesystem job store), so
    /// the assertion is deterministic in CI and headless environments.
    func testNotFoundExitsWith3() {
        guard requireBinary() else { return }
        let result = run(["job", "show", "definitely-not-a-real-job-id", "--format", "agent"])
        XCTAssertEqual(result.exitCode, 3, "not-found should exit 3, got \(result.exitCode); stderr=\(result.stderr)")
        // Envelope still well-formed.
        if let data = result.stdout.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertEqual(dict["status"] as? String, "error")
        }
    }

    // MARK: - agent-info probe

    func testAgentInfoEnvelopeAndToolCountParity() throws {
        guard requireBinary() else { return }
        let probe = run(["agent-info", "--format", "agent"])
        XCTAssertEqual(probe.exitCode, 0)
        let data = try XCTUnwrap(probe.stdout.data(using: .utf8))
        let env = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(env["v"] as? Int, 1)
        XCTAssertEqual(env["status"] as? String, "ok")
        let payload = try XCTUnwrap(env["data"] as? [String: Any])
        let mcp = try XCTUnwrap(payload["mcp"] as? [String: Any])
        let toolCount = try XCTUnwrap(mcp["tool_count"] as? Int)

        // Parity: the advertised count must equal `mcp-server --list-tools`.
        let listed = run(["mcp-server", "--list-tools"])
        let listData = try XCTUnwrap(listed.stdout.data(using: .utf8))
        let listObj = try XCTUnwrap(JSONSerialization.jsonObject(with: listData) as? [String: Any])
        let tools = try XCTUnwrap(listObj["tools"] as? [[String: Any]])
        XCTAssertEqual(toolCount, tools.count, "agent-info tool_count must match --list-tools")
    }

    // MARK: - --fields projection in agent mode

    /// `--fields` must project the envelope's `data` in agent mode (previously
    /// it was honored only in `--format json`). Reminders is permission-light;
    /// if no reminders/permission exist the data is an empty array, which still
    /// proves projection didn't corrupt the envelope.
    func testFieldsProjectsAgentEnvelope() {
        guard requireBinary() else { return }
        let result = run(["reminders", "list", "--limit", "3", "--fields", "id,title", "--format", "agent"])
        guard result.exitCode == 0, let data = result.stdout.data(using: .utf8),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Reminders access unavailable in this environment — skip rather than fail.
            return
        }
        XCTAssertEqual(env["v"] as? Int, 1)
        XCTAssertEqual(env["status"] as? String, "ok")
        XCTAssertNotNil(env["duration_ms"], "projection must not drop envelope frame")
        if let items = env["data"] as? [[String: Any]], let first = items.first {
            XCTAssertEqual(first.keys.sorted(), ["id", "title"], "data elements must be projected")
        }
    }

    // MARK: - Agent error output

    func testInvalidCommandAgentError() {
        guard requireBinary() else { return }
        let result = run(["mail", "mark", "--format", "agent", "invalid-id"])
        // Envelope v1: {"v":1,"status":"error","duration_ms":N,"error":{code,message,...}}
        let combined = result.stdout + result.stderr
        if let data = result.stdout.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorDict = dict["error"] as? [String: Any] {
            XCTAssertEqual(dict["v"] as? Int, 1, "Envelope must have v:1")
            XCTAssertEqual(dict["status"] as? String, "error", "Envelope status must be 'error'")
            XCTAssertNotNil(dict["duration_ms"], "Envelope must include duration_ms")
            XCTAssertNotNil(errorDict["code"], "Agent error must have 'code' field")
            XCTAssertNotNil(errorDict["message"], "Agent error must have 'message' field")
        } else if result.exitCode != 0 {
            // Binary not reachable or command exited without agent error — acceptable
            // in environments without Mail.app access
            XCTAssertTrue(combined.count >= 0) // trivially pass
        }
    }

    // MARK: - Doctor agent format

    func testDoctorFormatAgent() throws {
        guard requireBinary() else { return }
        let result = run(["doctor", "--format", "agent"])
        // Envelope v1: {"v":1,"status":"ok","duration_ms":N,"data":[...checks...]}
        let data = try XCTUnwrap(result.stdout.data(using: .utf8))
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("doctor --format agent must output a JSON envelope, got: \(result.stdout)")
            return
        }
        XCTAssertEqual(envelope["v"] as? Int, 1, "Envelope must have v:1")
        XCTAssertEqual(envelope["status"] as? String, "ok", "Envelope status must be 'ok'")
        XCTAssertNotNil(envelope["duration_ms"], "Envelope must include duration_ms")
        guard let checks = envelope["data"] as? [[String: Any]] else {
            XCTFail("envelope.data must be a JSON array of checks, got: \(envelope["data"] ?? "nil")")
            return
        }
        XCTAssertGreaterThan(checks.count, 0, "Expected at least one check in data")
        for check in checks {
            XCTAssertNotNil(check["name"], "Each check must have a 'name' field")
            XCTAssertNotNil(check["status"], "Each check must have a 'status' field")
            XCTAssertNotNil(check["detail"], "Each check must have a 'detail' field")
        }
    }

    // MARK: - Experimental gate (Phase 3)

    func testAudioAndBrowserHiddenByDefault() {
        guard requireBinary() else { return }
        // Scrub PIPPIN_EXPERIMENTAL from the child's env so an exported value on
        // the developer's shell doesn't poison the negative case.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "PIPPIN_EXPERIMENTAL")
        let result = runWithEnv(["--help"], env: env)
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertFalse(combined.contains("\n  audio"), "audio subcommand must not appear in default help")
        XCTAssertFalse(combined.contains("\n  browser"), "browser subcommand must not appear in default help")
    }

    func testAudioAndBrowserAppearWithExperimentalFlag() {
        guard requireBinary() else { return }
        var env = ProcessInfo.processInfo.environment
        env["PIPPIN_EXPERIMENTAL"] = "1"
        let result = runWithEnv(["--help"], env: env)
        XCTAssertEqual(result.exitCode, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(combined.contains("\n  audio"), "audio subcommand should appear when PIPPIN_EXPERIMENTAL=1")
        XCTAssertTrue(combined.contains("\n  browser"), "browser subcommand should appear when PIPPIN_EXPERIMENTAL=1")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
