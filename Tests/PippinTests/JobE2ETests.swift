@testable import PippinLib
import XCTest

/// End-to-end tests for `pippin job run` / `show` / `wait`. These spawn the
/// real pippin binary as a detached child, so the binary must be built
/// before the suite runs. Skipped when the binary is absent.
final class JobE2ETests: XCTestCase {
    nonisolated(unsafe) static var binaryURL: URL?
    var overrideHome: String!
    var originalHome: String?

    override class func setUp() {
        super.setUp()
        let result = runProcess("/usr/bin/swift", args: ["build", "--show-bin-path"])
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: trimmed).appendingPathComponent("pippin")
        if FileManager.default.fileExists(atPath: url.path) {
            binaryURL = url
        }
    }

    override func setUp() {
        super.setUp()
        // Isolate the job cache by overriding HOME for each test so real
        // user jobs never collide with test artifacts.
        overrideHome = NSTemporaryDirectory() + "pippin-job-e2e-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: overrideHome, withIntermediateDirectories: true)
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", overrideHome, 1)
    }

    override func tearDown() {
        if let originalHome { setenv("HOME", originalHome, 1) } else { unsetenv("HOME") }
        try? FileManager.default.removeItem(atPath: overrideHome)
        super.tearDown()
    }

    private func requireBinary(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if Self.binaryURL == nil {
            XCTFail("pippin binary not found — run `swift build`", file: file, line: line)
            return false
        }
        return true
    }

    @discardableResult
    static func runProcess(
        _ executable: String,
        args: [String],
        env: [String: String]? = nil,
        timeoutSeconds: TimeInterval = 30
    ) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let env { process.environment = env }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        guard (try? process.run()) != nil else {
            return ("", "failed to launch \(executable)", -1)
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return ("", "timeout after \(timeoutSeconds)s", -1)
        }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, process.terminationStatus)
    }

    private func runPippin(
        _ args: [String],
        timeoutSeconds: TimeInterval = 30
    ) -> (stdout: String, stderr: String, exitCode: Int32) {
        guard let binary = Self.binaryURL else { return ("", "", 0) }
        let env = ProcessInfo.processInfo.environment.merging(
            ["HOME": overrideHome],
            uniquingKeysWith: { _, new in new }
        )
        return Self.runProcess(
            binary.path, args: args, env: env, timeoutSeconds: timeoutSeconds
        )
    }

    private func parseEnvelopeData(_ stdout: String) throws -> [String: Any] {
        let data = Data(stdout.utf8)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "JobE2E", code: 1)
        }
        if let err = obj["error"] as? [String: Any] {
            throw NSError(domain: "JobE2E", code: 2, userInfo: ["err": err])
        }
        guard let data = obj["data"] as? [String: Any] else {
            throw NSError(domain: "JobE2E", code: 3)
        }
        return data
    }

    // MARK: - Lifecycle

    /// Smoke test: run a short job, poll via `job show`, verify it transitions
    /// to `done`. Uses `pippin doctor` as the workload — fast and no side effects.
    func testRunPollDoneLifecycle() throws {
        guard requireBinary() else { return }

        // Launch a short job. `doctor` runs quickly.
        let runResult = runPippin(["job", "run", "--format", "agent", "--", "doctor"])
        XCTAssertEqual(runResult.exitCode, 0, "run failed: \(runResult.stderr)")
        let runData = try parseEnvelopeData(runResult.stdout)
        let jobId = try XCTUnwrap(runData["id"] as? String)
        XCTAssertFalse(jobId.isEmpty)

        // Poll show until terminal.
        let deadline = Date().addingTimeInterval(10)
        var final: [String: Any]?
        while Date() < deadline {
            let show = runPippin(["job", "show", jobId, "--format", "agent"])
            XCTAssertEqual(show.exitCode, 0, "show failed: \(show.stderr)")
            let payload = try parseEnvelopeData(show.stdout)
            let status = payload["status"] as? String ?? ""
            if status != "running" {
                final = payload
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let payload = try XCTUnwrap(final, "job did not reach terminal state within 10s")
        XCTAssertNotEqual(payload["status"] as? String, "running")
        XCTAssertNotNil(payload["ended_at"], "terminal job should have ended_at")
        XCTAssertNotNil(payload["duration_ms"], "terminal job should have duration_ms")
    }

    /// Rejects an empty argv with an envelope error.
    func testRunRejectsEmptyArgv() {
        guard requireBinary() else { return }
        let result = runPippin(["job", "run", "--format", "agent"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    /// `pippin job list` returns the newly-created job alongside its id.
    func testListIncludesNewJob() throws {
        guard requireBinary() else { return }
        let runResult = runPippin(["job", "run", "--format", "agent", "--", "doctor"])
        let runData = try parseEnvelopeData(runResult.stdout)
        let jobId = try XCTUnwrap(runData["id"] as? String)

        let listResult = runPippin(["job", "list", "--format", "agent"])
        XCTAssertEqual(listResult.exitCode, 0, "list failed: \(listResult.stderr)")
        let obj = try JSONSerialization.jsonObject(with: Data(listResult.stdout.utf8)) as? [String: Any]
        let jobs = (obj?["data"] as? [[String: Any]]) ?? []
        let ids = jobs.compactMap { $0["id"] as? String }
        XCTAssertTrue(ids.contains(jobId), "job \(jobId) not in list: \(ids)")
    }
}
