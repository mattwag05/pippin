@testable import PippinLib
import XCTest

/// RC-14: a `Date` that reaches the envelope encoder must come out as an ISO
/// 8601 string, not as seconds since 2001.
final class EnvelopeDateTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
    private let ended = Date(timeIntervalSince1970: 1_800_000_042)

    private func data(_ json: String) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try XCTUnwrap(root["data"] as? [String: Any])
    }

    private var job: Job {
        Job(id: "abc", argv: ["doctor"], pid: 7, status: .done, exitCode: 0, startedAt: started, endedAt: ended)
    }

    func testJobDatesAreISOStringsInTheEnvelope() throws {
        let payload = try data(agentJSON(job))
        XCTAssertEqual(payload["started_at"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(payload["ended_at"] as? String, "2027-01-15T08:00:42Z")
        XCTAssertEqual(payload["duration_ms"] as? Int, 42000)
    }

    func testJobShowAndGcDatesAreISOStrings() throws {
        let view = try data(agentJSON(JobView(job: job, stdoutTail: "", stderrTail: "")))
        XCTAssertEqual(view["started_at"] as? String, "2027-01-15T08:00:00Z")
        XCTAssertEqual(view["ended_at"] as? String, "2027-01-15T08:00:42Z")
        let gc = try data(agentJSON(GcResult(removed: [], cutoff: started)))
        XCTAssertEqual(gc["cutoff"] as? String, "2027-01-15T08:00:00Z")
    }

    func testProjectedEnvelopeUsesTheSameDateFormat() throws {
        let payload = try data(projectedAgentJSON(job, fields: ["id", "started_at"]))
        XCTAssertEqual(payload["started_at"] as? String, "2027-01-15T08:00:00Z")
    }

    func testMemoSummaryDateIsAnISOString() throws {
        let result = SummarizeResult(
            id: "m1", title: "t", createdAt: started, summary: "s", template: nil, provider: "ollama"
        )
        XCTAssertEqual(try data(agentJSON(result))["createdAt"] as? String, "2027-01-15T08:00:00Z")
    }

    /// A status.json written by an earlier release still loads.
    func testOldOnDiskJobRecordStillDecodes() throws {
        let store = JobStore(root: NSTemporaryDirectory() + "pippin-jobs-old-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: store.root) }
        try store.createDir("0123456789abcdef")
        let old = """
        {"argv":["mail","index"],"duration_ms":42000,"ended_at":"2027-01-15T08:00:42Z","exit_code":0,
         "id":"0123456789abcdef","pid":7,"started_at":"2027-01-15T08:00:00Z","status":"done","v":1}
        """
        try old.write(toFile: store.statusPath("0123456789abcdef"), atomically: true, encoding: .utf8)
        let loaded = try store.read("0123456789abcdef")
        XCTAssertEqual(loaded.startedAt, started)
        XCTAssertEqual(loaded.endedAt, ended)
        XCTAssertEqual(loaded.durationMs, 42000)
        XCTAssertNil(loaded.errorCode)
    }
}
