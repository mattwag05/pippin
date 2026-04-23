@testable import PippinLib
import XCTest

/// Tests for Envelope v1 — the breaking-change wrapper introduced in pippin-xy0.
/// Every `--format agent` response must wrap the original payload as
/// {"v":1,"status":"ok|error","duration_ms":N,"data":...} or
/// {"v":1,"status":"error","duration_ms":N,"error":{code,message,…}}.
final class AgentEnvelopeTests: XCTestCase {
    private struct Sample: Encodable, Equatable {
        let name: String
        let count: Int
    }

    // MARK: - Schema version

    func testSchemaVersionConstantIsOne() {
        XCTAssertEqual(AGENT_SCHEMA_VERSION, 1)
    }

    // MARK: - Ok envelope shape

    func testOkEnvelopeWrapsPayload() throws {
        let payload = Sample(name: "foo", count: 3)
        let capture = try captureStdout {
            try printAgentJSON(payload)
        }
        let json = try decodeObject(capture)
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertNotNil(json["duration_ms"] as? Int)
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["name"] as? String, "foo")
        XCTAssertEqual(data["count"] as? Int, 3)
        XCTAssertNil(json["error"], "Ok envelope must not carry 'error'")
    }

    func testOkEnvelopeIsCompactJSON() throws {
        let capture = try captureStdout {
            try printAgentJSON(Sample(name: "foo", count: 1))
        }
        XCTAssertFalse(capture.contains("\n  "), "Envelope must be compact (no pretty indent)")
        // Trailing newline from `print()` is expected; strip it before newline check.
        let trimmed = capture.trimmingCharacters(in: .newlines)
        XCTAssertFalse(trimmed.contains("\n"), "Envelope body must be single-line")
    }

    func testOkEnvelopeDurationReflectsStartedAt() throws {
        let past = Date(timeIntervalSinceNow: -0.1) // 100ms ago
        let capture = try captureStdout {
            try printAgentJSON(Sample(name: "x", count: 0), startedAt: past)
        }
        let json = try decodeObject(capture)
        let durationMs = try XCTUnwrap(json["duration_ms"] as? Int)
        XCTAssertGreaterThanOrEqual(durationMs, 100 - 20, "duration_ms must reflect startedAt")
        XCTAssertLessThan(durationMs, 2000, "duration_ms must not be absurdly large")
    }

    // MARK: - Error envelope shape

    func testErrorEnvelopeWrapsError() throws {
        struct Boom: Error, LocalizedError {
            var errorDescription: String? {
                "boom"
            }
        }
        let capture = try captureStdout {
            printAgentError(Boom())
        }
        let json = try decodeObject(capture)
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["status"] as? String, "error")
        XCTAssertNotNil(json["duration_ms"] as? Int)
        let errorDict = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(errorDict["message"] as? String, "boom")
        XCTAssertNotNil(errorDict["code"])
        XCTAssertNil(json["data"], "Error envelope must not carry 'data'")
    }

    func testErrorEnvelopeIncludesRemediationWhenCatalogued() throws {
        let capture = try captureStdout {
            printAgentError(CalendarBridgeError.accessDenied)
        }
        let json = try decodeObject(capture)
        let errorDict = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(errorDict["code"] as? String, "access_denied")
        XCTAssertNotNil(errorDict["remediation"], "access_denied is catalogued; remediation should be present")
    }

    // MARK: - Warnings (optional, omitted when empty)

    func testOkEnvelopeOmitsWarningsByDefault() throws {
        let capture = try captureStdout {
            try printAgentJSON(Sample(name: "x", count: 1))
        }
        let json = try decodeObject(capture)
        XCTAssertNil(json["warnings"], "warnings must be absent when none are passed")
    }

    func testOkEnvelopeOmitsWarningsWhenEmpty() throws {
        let capture = try captureStdout {
            try printAgentJSON(Sample(name: "x", count: 1), warnings: [])
        }
        let json = try decodeObject(capture)
        XCTAssertNil(json["warnings"], "empty warnings array must be omitted, not encoded as []")
    }

    func testOkEnvelopeIncludesWarningsWhenPresent() throws {
        let capture = try captureStdout {
            try printAgentJSON(
                Sample(name: "x", count: 1),
                warnings: ["partial results — narrow your query"]
            )
        }
        let json = try decodeObject(capture)
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertEqual(warnings, ["partial results — narrow your query"])
    }

    // MARK: - OutputOptions helper

    func testOutputOptionsPrintAgentWrapsAndThreadsStartedAt() throws {
        var opts = try OutputOptions.parse(["--format", "agent"])
        _ = opts // silence 'was never mutated' — parse returns a new struct each time
        // Parse, wait, print — duration should reflect the wait.
        let parsed = try OutputOptions.parse(["--format", "agent"])
        Thread.sleep(forTimeInterval: 0.05) // 50ms
        let capture = try captureStdout {
            try parsed.printAgent(Sample(name: "bar", count: 7))
        }
        let json = try decodeObject(capture)
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["status"] as? String, "ok")
        let durationMs = try XCTUnwrap(json["duration_ms"] as? Int)
        XCTAssertGreaterThanOrEqual(durationMs, 40, "OutputOptions.startedAt must be threaded through")
    }

    // MARK: - Helpers

    private func decodeObject(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try XCTUnwrap(trimmed.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "Envelope must decode as a top-level JSON object")
    }
}
