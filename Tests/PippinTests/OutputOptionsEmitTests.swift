@testable import PippinLib
import XCTest

/// Tests for `OutputOptions.emit(...)` — the shared timed-out-aware
/// emitter used by `MailCommand.Search` and `NotesCommand` (List/Search/
/// Folders). Behaviors:
/// - JSON: writes payload only (no envelope mutation).
/// - Agent: passes `[hint]` as `warnings` when timed out, omitted otherwise.
/// - Text: stderr `Warning:` + caller's renderer + trailing
///   `(partial results — ...)` when timed out.
/// - Stderr `Warning:` ALWAYS fires when timed out, regardless of format.
final class OutputOptionsEmitTests: XCTestCase {
    private struct Sample: Encodable {
        let n: Int
    }

    private static let hint = "search exceeded soft timeout, narrow with --foo"

    // MARK: - Agent path

    func testAgentEmitTimedOutAddsWarningsArray() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stdout = try captureStdout {
            try opts.emit(Sample(n: 1), timedOut: true, timedOutHint: Self.hint) {}
        }
        let json = try decodeObject(stdout)
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        XCTAssertEqual(warnings, [Self.hint])
    }

    func testAgentEmitNotTimedOutOmitsWarnings() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stdout = try captureStdout {
            try opts.emit(Sample(n: 1), timedOut: false, timedOutHint: Self.hint) {}
        }
        let json = try decodeObject(stdout)
        XCTAssertNil(json["warnings"], "warnings must be omitted when not timed out")
    }

    // MARK: - JSON path

    func testJsonEmitWritesRawPayloadIgnoringTimedOut() throws {
        // JSON path doesn't carry the warning in-band — only stderr + agent envelope do.
        let opts = try OutputOptions.parse(["--format", "json"])
        let stdout = try captureStdout {
            try opts.emit(Sample(n: 7), timedOut: true, timedOutHint: Self.hint) {}
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try XCTUnwrap(trimmed.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["n"] as? Int, 7)
        XCTAssertNil(json["warnings"], "JSON path must not inject warnings into the payload")
    }

    // MARK: - Text path

    func testTextEmitTimedOutCallsRendererAndAppendsTrailer() throws {
        let opts = try OutputOptions.parse(["--format", "text"])
        let stdout = try captureStdout {
            try opts.emit(Sample(n: 3), timedOut: true, timedOutHint: Self.hint) {
                print("body line")
            }
        }
        XCTAssertTrue(stdout.contains("body line"), "renderer must run")
        XCTAssertTrue(stdout.contains("(partial results — \(Self.hint))"))
    }

    func testTextEmitNotTimedOutOmitsTrailer() throws {
        let opts = try OutputOptions.parse(["--format", "text"])
        let stdout = try captureStdout {
            try opts.emit(Sample(n: 3), timedOut: false, timedOutHint: Self.hint) {
                print("body line")
            }
        }
        XCTAssertTrue(stdout.contains("body line"))
        XCTAssertFalse(stdout.contains("(partial results"), "no trailer when not timed out")
    }

    // MARK: - Stderr advisory

    func testTimedOutWritesStderrWarningInTextAndJsonOnly() throws {
        // Agent mode carries the advisory in the envelope `warnings` field —
        // duplicating it on stderr would create double-notification noise in
        // MCP logs (the MCP server captures child stderr too).
        for format in OutputFormat.allCases where format != .agent {
            let opts = try OutputOptions.parse(["--format", format.rawValue])
            let stderr = try captureStderr {
                try opts.emit(Sample(n: 1), timedOut: true, timedOutHint: Self.hint) {}
            }
            XCTAssertTrue(
                stderr.contains("Warning: \(Self.hint)"),
                "format=\(format.rawValue): expected stderr warning, got: \(stderr)"
            )
        }
    }

    func testTimedOutInAgentModeSuppressesStderrWarning() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stderr = try captureStderr {
            try opts.emit(Sample(n: 1), timedOut: true, timedOutHint: Self.hint) {}
        }
        XCTAssertFalse(
            stderr.contains("Warning:"),
            "agent mode must rely on envelope warnings, not stderr noise"
        )
    }

    func testNotTimedOutOmitsStderrWarning() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stderr = try captureStderr {
            try opts.emit(Sample(n: 1), timedOut: false, timedOutHint: Self.hint) {}
        }
        XCTAssertFalse(stderr.contains("Warning:"), "no stderr warning when not timed out")
    }

    // MARK: - Field projection defaults to `--fields` (pippin-sq6)

    private struct Row: Encodable {
        let id: String
        let title: String
    }

    func testPrintAgentAutoHonorsFieldsFlag() throws {
        // A direct printAgent call (no explicit `fields:` arg) must still honor
        // `--fields` — this is the case that was previously silently ignored at
        // sites like `mail accounts` / `reminders lists` / `contacts groups`.
        let opts = try OutputOptions.parse(["--format", "agent", "--fields", "id"])
        let stdout = try captureStdout {
            try opts.printAgent([Row(id: "a", title: "Alpha"), Row(id: "b", title: "Beta")])
        }
        let json = try decodeObject(stdout)
        let data = try XCTUnwrap(json["data"] as? [[String: Any]])
        XCTAssertEqual(data.count, 2)
        XCTAssertEqual(data[0]["id"] as? String, "a")
        XCTAssertNil(data[0]["title"], "--fields id must drop title")
    }

    func testPrintAgentNoFieldsEmitsFullPayload() throws {
        let opts = try OutputOptions.parse(["--format", "agent"])
        let stdout = try captureStdout {
            try opts.printAgent([Row(id: "a", title: "Alpha")])
        }
        let data = try XCTUnwrap(try decodeObject(stdout)["data"] as? [[String: Any]])
        XCTAssertEqual(data[0]["id"] as? String, "a")
        XCTAssertEqual(data[0]["title"] as? String, "Alpha", "no --fields → no projection")
    }

    func testExplicitFieldsArgOverridesFlag() throws {
        // An explicit `fields:` argument still wins over `--fields`.
        let opts = try OutputOptions.parse(["--format", "agent", "--fields", "id"])
        let stdout = try captureStdout {
            try opts.printAgent([Row(id: "a", title: "Alpha")], fields: ["title"])
        }
        let data = try XCTUnwrap(try decodeObject(stdout)["data"] as? [[String: Any]])
        XCTAssertEqual(data[0]["title"] as? String, "Alpha")
        XCTAssertNil(data[0]["id"], "explicit fields:[title] overrides --fields id")
    }

    func testEmitAgentAutoHonorsFieldsFlag() throws {
        let opts = try OutputOptions.parse(["--format", "agent", "--fields", "id"])
        let stdout = try captureStdout {
            try opts.emit([Row(id: "a", title: "Alpha")], timedOutHint: "") {}
        }
        let data = try XCTUnwrap(try decodeObject(stdout)["data"] as? [[String: Any]])
        XCTAssertEqual(data[0]["id"] as? String, "a")
        XCTAssertNil(data[0]["title"])
    }

    func testEmitJsonAutoHonorsFieldsFlag() throws {
        let opts = try OutputOptions.parse(["--format", "json", "--fields", "id"])
        let stdout = try captureStdout {
            try opts.emit([Row(id: "a", title: "Alpha")], timedOutHint: "") {}
        }
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let arr = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(trimmed.data(using: .utf8))) as? [[String: Any]]
        )
        XCTAssertEqual(arr[0]["id"] as? String, "a")
        XCTAssertNil(arr[0]["title"], "json mode must project from --fields too")
    }

    // MARK: - Helpers

    private func decodeObject(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try XCTUnwrap(trimmed.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
