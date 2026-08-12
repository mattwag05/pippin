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
        // v3 (2026-08-12): `data` keeps its type under pagination; the cursor
        // moved to a top-level `next_cursor` (pippin-37az).
        XCTAssertEqual(AGENT_SCHEMA_VERSION, 3)
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

    // MARK: - Partial marker (soft-timeout / unfinished-scan results)

    func testOkEnvelopeOmitsPartialByDefault() throws {
        let json = try decodeObject(captureStdout { try printAgentJSON(Sample(name: "x", count: 1)) })
        XCTAssertNil(json["partial"], "partial must be absent on a complete result")
    }

    func testOkEnvelopeIncludesPartialWhenTrue() throws {
        let json = try decodeObject(captureStdout {
            try printAgentJSON(Sample(name: "x", count: 1), partial: true)
        })
        XCTAssertEqual(json["partial"] as? Bool, true)
        XCTAssertEqual(json["status"] as? String, "ok", "partial rides on the ok envelope, status unchanged")
    }

    func testProjectedEnvelopeIncludesPartial() throws {
        let projected = try decodeObject(captureStdout {
            try printAgentProjectedJSON([Sample(name: "x", count: 1)], fields: ["name"], partial: true)
        })
        XCTAssertEqual(projected["partial"] as? Bool, true)
    }

    func testProjectedFrameMatchesTypedWithPartial() throws {
        let payload = [Sample(name: "foo", count: 3)]
        let typed = try decodeObject(captureStdout { try printAgentJSON(payload, partial: true) })
        let projected = try decodeObject(captureStdout {
            try printAgentProjectedJSON(payload, fields: ["name"], partial: true)
        })
        let frameKeys: (([String: Any]) -> Set<String>) = { Set($0.keys).subtracting(["data"]) }
        XCTAssertEqual(frameKeys(typed), frameKeys(projected), "hand-built partial frame must match the typed envelope")
    }

    // MARK: - Pagination cursor (envelope v3, pippin-37az)

    /// The regression: `.data` used to become `{items, next_cursor}` under any
    /// pagination flag while `v` stayed the same, so a consumer iterating
    /// `.data` silently iterated dict KEYS instead of rows.
    func testPaginatedDataStaysAnArrayAndCursorGoesTopLevel() throws {
        let parsed = try OutputOptions.parse(["--format", "agent"])
        let page = Page(items: [Sample(name: "foo", count: 3)], nextCursor: "tok123")
        let json = try decodeObject(captureStdout { try parsed.printAgentPage(page) })

        let data = try XCTUnwrap(json["data"] as? [[String: Any]], "data must stay an array under pagination")
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual(data.first?["name"] as? String, "foo")
        XCTAssertEqual(json["next_cursor"] as? String, "tok123")
        XCTAssertNil(json["data"] as? [String: Any], "data must not be re-wrapped as an object")
    }

    /// Type stability is the whole point: the same command paginated and not
    /// must hand back the same `data` type.
    func testPaginatedAndUnpaginatedDataTypesMatch() throws {
        let parsed = try OutputOptions.parse(["--format", "agent"])
        let items = [Sample(name: "foo", count: 3)]
        let plain = try decodeObject(captureStdout { try parsed.printAgent(items) })
        let paged = try decodeObject(captureStdout {
            try parsed.printAgentPage(Page(items: items, nextCursor: "tok"))
        })
        XCTAssertNotNil(plain["data"] as? [[String: Any]])
        XCTAssertNotNil(paged["data"] as? [[String: Any]])
        XCTAssertEqual(plain["data"] as? [[String: Any]] as NSArray?, paged["data"] as? [[String: Any]] as NSArray?)
    }

    /// An exhausted page carries no cursor at all — `next_cursor` is omitted,
    /// not null, so its absence is the end-of-results signal.
    func testExhaustedPageOmitsCursorEntirely() throws {
        let parsed = try OutputOptions.parse(["--format", "agent"])
        let json = try decodeObject(captureStdout {
            try parsed.printAgentPage(Page(items: [Sample(name: "foo", count: 3)], nextCursor: nil))
        })
        XCTAssertFalse(json.keys.contains("next_cursor"))
    }

    /// A non-paginated envelope must never grow the key.
    func testUnpaginatedEnvelopeHasNoCursorKey() throws {
        let json = try decodeObject(captureStdout { try printAgentJSON(Sample(name: "x", count: 1)) })
        XCTAssertFalse(json.keys.contains("next_cursor"))
    }

    /// `--fields` projects the page's ELEMENTS (data is an array now) while the
    /// cursor survives in the frame — previously projection had to special-case
    /// an `items` sibling to avoid dropping it.
    func testProjectionAppliesToPageItemsAndKeepsCursor() throws {
        let parsed = try OutputOptions.parse(["--format", "agent", "--fields", "name"])
        let page = Page(items: [Sample(name: "foo", count: 3)], nextCursor: "tok123")
        let json = try decodeObject(captureStdout { try parsed.printAgentPage(page) })
        let data = try XCTUnwrap(json["data"] as? [[String: Any]])
        XCTAssertEqual(data.first?.keys.sorted(), ["name"])
        XCTAssertEqual(json["next_cursor"] as? String, "tok123")
    }

    func testProjectedFrameMatchesTypedWithCursor() throws {
        let payload = [Sample(name: "foo", count: 3)]
        let typed = try decodeObject(captureStdout { try printAgentJSON(payload, nextCursor: "tok") })
        let projected = try decodeObject(captureStdout {
            try printAgentProjectedJSON(payload, fields: ["name"], nextCursor: "tok")
        })
        let frameKeys: (([String: Any]) -> Set<String>) = { Set($0.keys).subtracting(["data"]) }
        XCTAssertEqual(frameKeys(typed), frameKeys(projected), "hand-built cursor frame must match the typed envelope")
        XCTAssertEqual(projected["next_cursor"] as? String, "tok")
    }

    // MARK: - Helpers

    private func decodeObject(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try XCTUnwrap(trimmed.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "Envelope must decode as a top-level JSON object")
    }
}
