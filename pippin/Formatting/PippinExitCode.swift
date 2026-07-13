import Foundation

/// Maps Pippin's runtime errors to a small, documented set of process exit
/// codes so a calling shell or agent can branch on the *class* of failure
/// without parsing the JSON envelope. The envelope itself is unchanged — this
/// only sets `$?`.
///
/// The classification keys off the snake_case string that
/// `agentErrorCode(for:)` already derives from each error's enum case name, so
/// there is no parallel taxonomy to keep in sync: a new `fooNotFound` case
/// automatically lands in the `notFound` bucket.
///
/// Scheme (small integers, deliberately distinct from ArgumentParser's
/// `EX_USAGE` = 64 which still governs argument-parsing failures):
///
/// | Code | Meaning                         | Retryable | Example codes                                   |
/// |------|---------------------------------|-----------|-------------------------------------------------|
/// | 0    | success                         | —         | —                                               |
/// | 2    | usage / bad input               | no        | `invalid_cursor`, `invalid_json`, `missing_required` |
/// | 3    | resource not found              | no        | `event_not_found`, `memo_not_found`             |
/// | 4    | auth / permission / config      | no        | `access_denied`, `missing_api_key`, `not_available` |
/// | 5    | tool / bridge failure (default) | maybe     | `script_failed`, `database_error`               |
/// | 7    | timeout / rate-limit            | yes       | `timed_out`, `timeout`, `rate_limited`          |
///
/// Argument-parsing and `--help`/`--version` paths are intentionally NOT routed
/// through here — ArgumentParser keeps its own exit codes (`64` usage, `0`
/// help) so its formatted usage output is preserved.
public enum PippinExitCode {
    /// Generic catch-all for a tool/bridge failure or an unclassified runtime
    /// error.
    public static let toolFailure: Int32 = 5

    /// Classify an already-derived snake_case agent error code into a process
    /// exit code. Pure and total — every input maps to exactly one code,
    /// defaulting to `toolFailure` (5).
    public static func classify(_ code: String) -> Int32 {
        // Check the retryable bucket first so any current or future
        // `*_timed_out` / `*_rate_limited*` code lands on 7 regardless of what
        // other substrings it carries.
        if code.contains("timed_out") || code == "timeout" || code.contains("rate_limit") {
            return 7
        }
        if code == "access_denied"
            || code.contains("not_authorized")
            || code == "missing_api_key"
            || code == "not_available" {
            return 4
        }
        if code == "not_found" || code.hasSuffix("_not_found") {
            return 3
        }
        if code == "missing_required" || code.hasPrefix("invalid_") {
            return 2
        }
        return toolFailure
    }

    /// Derive the process exit code for any error by first reducing it to its
    /// agent error code (the same string surfaced as `error.code` in the
    /// agent-mode envelope), then classifying.
    public static func from(_ error: Error) -> Int32 {
        // ArgumentParser wraps thrown `ValidationError`s and parse-time failures
        // (missing required arg, unknown flag) in its own error types, whose
        // derived codes (`validation_error`/`command_error`) would otherwise
        // fall to the default tool-failure bucket. These are bad-input/usage
        // errors → exit 2, matching ArgumentParser's own EX_USAGE intent and the
        // agent-mode message recovery in `AgentError`. `CleanExit`/`ExitCode`
        // (--help/--version) never reach here — `Pippin.main` intercepts them
        // first. (pippin-3sy)
        if String(reflecting: type(of: error)).hasPrefix("ArgumentParser.") {
            return 2
        }
        return classify(agentErrorCode(for: error))
    }
}
