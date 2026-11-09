@testable import PippinLib
import XCTest

/// Tests for `AgentResult.emit(...)`, the shared timed-out-aware result, and
/// for `--format` parsing now that the agent envelope is the only output.
/// `[hint]` lands in the envelope's `warnings` when timed out and stderr stays
/// silent.
final class OutputOptionsEmitTests: XCTestCase {
    private struct Sample: Encodable {
        let n: Int
    }

    private static let hint = "search exceeded soft timeout, narrow with --foo"

    // MARK: - --format parsing

    func testAgentIsTheOnlyFormat() {
        XCTAssertEqual(OutputFormat.allCases, [.agent])
    }

    func testFormatDefaultsToAgent() throws {
        XCTAssertEqual(try OutputOptions.parse([]).format, .agent)
    }

    func testFormatAgentParses() throws {
        XCTAssertEqual(try OutputOptions.parse(["--format", "agent"]).format, .agent)
    }

    func testRemovedFormatsThrowAndNameTheReplacement() {
        for removed in ["text", "json"] {
            XCTAssertThrowsError(try OutputOptions.parse(["--format", removed]), removed) { error in
                let message = OutputOptions.message(for: error)
                XCTAssertTrue(message.contains("--format \(removed) was removed"), "got: \(message)")
                XCTAssertTrue(message.contains("--format agent"), "got: \(message)")
                XCTAssertEqual(PippinExitCode.from(error), 2, "argument errors exit 2")
            }
        }
    }

    // MARK: - Agent path

    func testAgentEmitTimedOutAddsWarningsArray() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stdout = try opts.render(.emit(Sample(n: 1), timedOut: true, timedOutHint: Self.hint))
        let json = try decodeObject(stdout)
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertEqual(warnings, [Self.hint])
    }

    func testAgentEmitNotTimedOutOmitsWarnings() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stdout = try opts.render(.emit(Sample(n: 1), timedOut: false, timedOutHint: Self.hint))
        let json = try decodeObject(stdout)
        XCTAssertNil(json["warnings"], "warnings must be omitted when not timed out")
    }

    // MARK: - Stderr advisory

    func testTimedOutInAgentModeSuppressesStderrWarning() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stderr = try captureStderr {
            _ = try opts.render(.emit(Sample(n: 1), timedOut: true, timedOutHint: Self.hint))
        }
        XCTAssertFalse(
            stderr.contains("Warning:"),
            "agent mode must rely on envelope warnings, not stderr noise"
        )
    }

    func testNotTimedOutOmitsStderrWarning() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stderr = try captureStderr {
            _ = try opts.render(.emit(Sample(n: 1), timedOut: false, timedOutHint: Self.hint))
        }
        XCTAssertFalse(stderr.contains("Warning:"), "no stderr warning when not timed out")
    }

    // MARK: - Partial marker + extra warnings (pippin-1son)

    func testAgentEmitTimedOutSetsPartialTrue() throws {
        // The whole point: a timed-out empty result must be machine-
        // distinguishable from a clean zero-match.
        let opts = try OutputOptions.parse(["--format", "agent"])
        let json = try decodeObject(opts.render(.emit(Sample(n: 1), timedOut: true, timedOutHint: Self.hint)))
        XCTAssertEqual(json["partial"] as? Bool, true)
    }

    func testAgentEmitNotTimedOutOmitsPartial() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let json = try decodeObject(opts.render(.emit(Sample(n: 1), timedOut: false, timedOutHint: Self.hint)))
        XCTAssertNil(json["partial"], "clean result must not carry partial")
    }

    func testAgentEmitExtraWarningsSurfaceWithoutPartial() throws {
        // A fast-path fallback note is an advisory, not a partial result.
        let opts = try OutputOptions.parse(["--format", "agent"])
        let json = try decodeObject(opts.render(.emit(Sample(n: 1), timedOut: false, timedOutHint: Self.hint, extraWarnings: ["fell back to JXA"])))
        XCTAssertEqual(json["warnings"] as? [String], ["fell back to JXA"])
        XCTAssertNil(json["partial"])
    }

    func testAgentEmitTimedOutPlusExtraWarningsMergesBoth() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let json = try decodeObject(opts.render(.emit(Sample(n: 1), timedOut: true, timedOutHint: Self.hint, extraWarnings: ["fell back to JXA"])))
        XCTAssertEqual(json["warnings"] as? [String], [Self.hint, "fell back to JXA"])
        XCTAssertEqual(json["partial"] as? Bool, true)
    }

    // MARK: - Field projection defaults to `--fields` (pippin-sq6)

    private struct Row: Encodable {
        let id: String
        let title: String
    }

    func testRenderAutoHonorsFieldsFlag() throws {
        // A result with no explicit `fields:` must still honor
        // `--fields` — this is the case that was previously silently ignored at
        // sites like `mail accounts` / `reminders lists` / `contacts groups`.
        let opts = try OutputOptions.parse(["--format", "agent", "--fields", "id"])
        let stdout = try opts.render(AgentResult([Row(id: "a", title: "Alpha"), Row(id: "b", title: "Beta")]))
        let json = try decodeObject(stdout)
        let data = try XCTUnwrap(json["data"] as? [[String: Any]])
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(data[0]["id"] as? String, "a")
        XCTAssertNil(data[0]["title"], "--fields id must drop title")
    }

    func testRenderNoFieldsEmitsFullPayload() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stdout = try opts.render(AgentResult([Row(id: "a", title: "Alpha")]))
        let data = try XCTUnwrap(try decodeObject(stdout)["data"] as? [[String: Any]])
        XCTAssertEqual(data[0]["id"] as? String, "a")
        XCTAssertEqual(data[0]["title"] as? String, "Alpha", "no --fields → no projection")
    }

    func testExplicitFieldsArgOverridesFlag() throws {
        // An explicit `fields:` argument still wins over `--fields`.
        let opts = try OutputOptions.parse(["--format", "agent", "--fields", "id"])
        let stdout = try opts.render(AgentResult([Row(id: "a", title: "Alpha")], fields: ["title"]))
        let data = try XCTUnwrap(try decodeObject(stdout)["data"] as? [[String: Any]])
        XCTAssertEqual(data[0]["title"] as? String, "Alpha")
        XCTAssertNil(data[0]["id"], "explicit fields:[title] overrides --fields id")
    }

    func testEmitAgentAutoHonorsFieldsFlag() throws {
        let opts = try OutputOptions.parse(["--format", "agent", "--fields", "id"])
        let stdout = try opts.render(.emit([Row(id: "a", title: "Alpha")], timedOutHint: ""))
        let data = try XCTUnwrap(try decodeObject(stdout)["data"] as? [[String: Any]])
        XCTAssertEqual(data[0]["id"] as? String, "a")
        XCTAssertNil(data[0]["title"])
    }

    // MARK: - Helpers

    private func decodeObject(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try XCTUnwrap(trimmed.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
