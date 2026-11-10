@testable import PippinLib
import XCTest

/// RC-13: a job whose runner died must not stay `running` forever.
final class JobRunnerLostTests: XCTestCase {
    private var store: JobStore!

    override func setUp() {
        super.setUp()
        store = JobStore(root: NSTemporaryDirectory() + "pippin-jobs-lost-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: store.root)
        super.tearDown()
    }

    private func writeRunning(pid: Int32?, startedAt: Date = Date()) throws -> String {
        let id = JobId.generate()
        try store.createDir(id)
        try store.write(Job(id: id, argv: ["mail", "list"], pid: pid, status: .running, startedAt: startedAt))
        return id
    }

    /// A pid that was real and is now certainly gone.
    private func deadPid() throws -> Int32 {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        return child.processIdentifier
    }

    func testRunningJobWithDeadRunnerBecomesRunnerLostAndStaysSo() throws {
        let id = try writeRunning(pid: deadPid())
        let job = try store.read(id)
        XCTAssertEqual(job.status, .error)
        XCTAssertEqual(job.errorCode, "runner_lost")
        XCTAssertNotNil(job.endedAt)
        // Persisted, so every later reader sees the same terminal record.
        let raw = try store.readCanonical(id, reconcile: false)
        XCTAssertEqual(raw.status, .error)
        XCTAssertEqual(try store.read(id).endedAt, raw.endedAt)
        XCTAssertEqual(store.all().first { $0.id == id }?.errorCode, "runner_lost")
    }

    func testRunningJobWithLiveRunnerStaysRunning() throws {
        let startedAt = Date()
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/sleep")
        runner.arguments = ["30"]
        try runner.run()
        defer { runner.terminate() }
        let id = try writeRunning(pid: runner.processIdentifier, startedAt: startedAt)
        XCTAssertEqual(try store.read(id).status, .running)
    }

    func testLivePidThatStartedAtAnotherTimeIsAReusedPid() throws {
        // This test process is alive, but it did not start a day ago.
        let id = try writeRunning(pid: getpid(), startedAt: Date().addingTimeInterval(-86400))
        XCTAssertEqual(try store.read(id).errorCode, "runner_lost")
    }

    func testJobWithoutAPidGetsALaunchGraceThenIsLost() throws {
        let fresh = try writeRunning(pid: nil)
        XCTAssertEqual(try store.read(fresh).status, .running)
        let stale = try writeRunning(pid: nil, startedAt: Date().addingTimeInterval(-600))
        XCTAssertEqual(try store.read(stale).errorCode, "runner_lost")
    }

    func testTerminalJobIsNeverRewritten() throws {
        let id = JobId.generate()
        try store.createDir(id)
        try store.write(Job(id: id, argv: ["x"], pid: deadPid(), status: .done, exitCode: 0, endedAt: Date()))
        let job = try store.read(id)
        XCTAssertEqual(job.status, .done)
        XCTAssertNil(job.errorCode)
    }

    func testJobWaitReturnsForALostRunnerInsteadOfTimingOut() async throws {
        let id = try writeRunning(pid: deadPid())
        let start = Date()
        let job = try await JobCommand.Wait.wait(store: store, id: id, timeout: 20, pollMs: 50)
        XCTAssertEqual(job.status, .error)
        XCTAssertEqual(job.errorCode, "runner_lost")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunnerLostIsEmittedAsErrorCode() throws {
        let id = try writeRunning(pid: deadPid())
        let text = try agentJSON(store.read(id))
        XCTAssertTrue(text.contains(#""error_code":"runner_lost""#), text)
        let view = try agentJSON(JobView(job: store.read(id), stdoutTail: "", stderrTail: ""))
        XCTAssertTrue(view.contains(#""error_code":"runner_lost""#), view)
    }
}
