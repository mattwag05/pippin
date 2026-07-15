@testable import PippinLib
import XCTest

/// Tests for the agent-mode envelope (v1 introduced in pippin-xy0; v2 in the
/// 2026-07-15 audit batch). Every `--format agent` response must wrap the
/// original payload as {"v":N,"status":"ok|error","duration_ms":M,"data":...}
/// or {"v":N,"status":"error","duration_ms":M,"error":{code,message,…}}, where
/// N is `AGENT_SCHEMA_VERSION`.
final class AgentEnvelopeTests: XCTestCase {
    private struct Sample: Encodable, Equatable {
        let name: String
        let count: Int
    }

    // MARK: - Schema version

    func testSchemaVersionConstant() {
        // v2 (2026-07-15): payload-shape changes — messages bare array, notes
        // createdAt/modifiedAt, all-day date-only, memos millis.
        XCTAssertEqual(AGENT_SCHEMA_VERSION, 2)
    }

    // MARK: - Ok envelope shape

    func testOkEnvelopeWrapsPayload() throws {
        let payload = Sample(name: "foo", count: 3)
        let capture = try captureStdout {
            try printAgentJSON(payload)
        }
        let json = try decodeObject(capture)
        XCTAssertEqual(json["v"] as? Int, AGENT_SCHEMA_VERSION)
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
        XCTAssertEqual(json["v"] as? Int, AGENT_SCHEMA_VERSION)
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
        XCTAssertEqual(json["v"] as? Int, AGENT_SCHEMA_VERSION)
        XCTAssertEqual(json["status"] as? String, "ok")
        let durationMs = try XCTUnwrap(json["duration_ms"] as? Int)
        XCTAssertGreaterThanOrEqual(durationMs, 40, "OutputOptions.startedAt must be threaded through")
    }

    // MARK: - Projected envelope (--fields) frame parity

    /// `printAgentProjectedJSON` hand-builds the envelope frame because its
    /// `data` is opaque projected JSON. This guards against the hand-built frame
    /// drifting from the typed `AgentOkEnvelope` if the envelope shape evolves.
    func testProjectedFrameMatchesTyped() throws {
        let payload = [Sample(name: "foo", count: 3)]
        let typed = try decodeObject(captureStdout { try printAgentJSON(payload) })
        let projected = try decodeObject(captureStdout { try printAgentProjectedJSON(payload, fields: ["name"]) })
        // Same top-level frame keys (everything except the payload itself).
        let frameKeys: (([String: Any]) -> Set<String>) = { Set($0.keys).subtracting(["data"]) }
        XCTAssertEqual(frameKeys(typed), frameKeys(projected), "projected envelope frame must match the typed envelope")
        XCTAssertEqual(projected["v"] as? Int, AGENT_SCHEMA_VERSION)
        XCTAssertEqual(projected["status"] as? String, "ok")
        XCTAssertNotNil(projected["duration_ms"] as? Int)
        // Projection actually trimmed the data.
        let items = try XCTUnwrap(projected["data"] as? [[String: Any]])
        XCTAssertEqual(items.first?.keys.sorted(), ["name"])
    }

    func testProjectedEnvelopeIncludesWarnings() throws {
        let projected = try decodeObject(captureStdout {
            try printAgentProjectedJSON([Sample(name: "x", count: 1)], fields: ["name"], warnings: ["partial"])
        })
        XCTAssertEqual(projected["warnings"] as? [String], ["partial"])
    }

    // MARK: - Helpers

    private func decodeObject(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try XCTUnwrap(trimmed.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "Envelope must decode as a top-level JSON object")
    }
}
