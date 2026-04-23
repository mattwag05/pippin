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

    // MARK: - Helpers

    private func decodeObject(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try XCTUnwrap(trimmed.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
