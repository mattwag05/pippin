import Foundation
@testable import PippinLib
import XCTest

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// Stands in for the child `pippin`: records every argv and answers from
/// `respond`. Nothing here can reach a real app.
final class FakeRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let respond: @Sendable ([String]) throws -> (text: String, isError: Bool)

    init(respond: @escaping @Sendable ([String]) throws -> (text: String, isError: Bool) = { _ in (#"{"v":4,"status":"ok","duration_ms":1,"data":{"success":true}}"#, false) }) {
        self.respond = respond
    }

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Calls that would change something: not a preview and not a `show`.
    var actingCalls: [[String]] {
        calls.filter { !$0.prefix { $0 != "--" }.contains("--dry-run") && !$0.contains("show") }
    }

    var run: ArgvRunner {
        { [self] argv in
            lock.withLock { recorded.append(argv) }
            return try respond(argv)
        }
    }
}

/// A temp policy path, state directory and gate, removed on tearDown.
struct SafetySandbox {
    let root: String
    let clock = TestClock()

    init() {
        root = NSTemporaryDirectory() + "pippin-safety-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    var policyPath: String { root + "/policy.json" }
    var stateDir: String { root + "/state" }
    var logPath: String { stateDir + "/actions.jsonl" }

    func writePolicy(_ json: String) throws {
        try json.write(toFile: policyPath, atomically: true, encoding: .utf8)
    }

    /// A new gate over the same files: what a restarted server would be.
    func gate() -> SafetyGate {
        SafetyGate(policyPath: policyPath, stateDir: stateDir, now: { [clock] in clock.now })
    }

    func logText() -> String {
        (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
    }

    func logLines() -> [ActionLogLine] {
        ActionLog(path: logPath).lines()
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

func safetyTool(_ name: String) throws -> MCPTool {
    try XCTUnwrap(MCPToolRegistry.tool(named: name), name)
}


extension SafetyGate {
    /// `run` against the real registry, returning the thrown refusal as a value.
    func attempt(_ name: String, _ arguments: JSONValue, runner: FakeRunner) async -> Result<(text: String, isError: Bool), Error> {
        do {
            let tool = try safetyTool(name)
            return try await .success(run(tool: tool, arguments: arguments, tools: MCPToolRegistry.tools, runArgv: runner.run))
        } catch {
            return .failure(error)
        }
    }
}

extension Result where Failure == Error {
    var safetyError: SafetyError? {
        if case let .failure(error) = self { return error as? SafetyError }
        return nil
    }

    var code: String? {
        if case let .failure(error) = self { return agentErrorCode(for: error) }
        return nil
    }
}
