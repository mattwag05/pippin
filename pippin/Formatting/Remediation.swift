import Foundation

/// A structured remediation hint attached to typed errors. Keyed by the
/// snake_case error code that `agentErrorCode(for:)` produces.
///
/// Fields:
/// - `humanHint`: one- or two-sentence actionable explanation for the user.
/// - `doctorCheck`: name of the `pippin doctor` check that covers the same
///   ground (matches `DiagnosticCheck.name` values). Pointing at this lets
///   the user re-run diagnostics after remediation.
/// - `shellCommand`: optional single-line shell command that resolves the
///   issue directly, when one exists.
public struct Remediation: Codable, Sendable, Equatable {
    public let humanHint: String
    public let doctorCheck: String
    public let shellCommand: String?

    public init(humanHint: String, doctorCheck: String, shellCommand: String? = nil) {
        self.humanHint = humanHint
        self.doctorCheck = doctorCheck
        self.shellCommand = shellCommand
    }

    private enum CodingKeys: String, CodingKey {
        case humanHint = "human_hint"
        case doctorCheck = "doctor_check"
        case shellCommand = "shell_command"
    }
    // Synthesized encode(to:) uses encodeIfPresent for Optional → shell_command
    // is omitted (not null) when nil, matching the prior hand-rolled shape.
}

/// Closed set of error codes that have a catalogued remediation. The raw
/// value is the snake_case string that `agentErrorCode(for:)` produces from
/// the matching Swift error case — keeping them coupled means a typo on
/// either side fails to compile rather than silently breaking the lookup.
public enum ErrorCategory: String, CaseIterable, Sendable {
    case accessDenied = "access_denied"
    case databaseNotFound = "database_not_found"
    case notAvailable = "not_available"
}

/// Central catalog mapping agent error codes (`AgentError.code`) to
/// user-facing remediation hints. When a new typed error is added to
/// `PippinLib`, add its snake_case code to `ErrorCategory` and register
/// the remediation in `forCategory(_:)` — the exhaustive switch forces
/// you to supply text for every case.
///
/// The catalog is intentionally small and hand-curated — it holds the
/// errors whose remediation is stable and well-understood. Unknown codes
/// return `nil`, which the callers handle gracefully (no remediation block
/// in the output).
public enum RemediationCatalog {
    /// Type-safe lookup. Every `ErrorCategory` case is guaranteed to have
    /// text — compile-time enforcement via exhaustive switch.
    public static func forCategory(_ category: ErrorCategory) -> Remediation {
        switch category {
        case .accessDenied:
            return Remediation(
                humanHint: """
                Voice Memos requires Full Disk Access. Open System Settings > \
                Privacy & Security > Full Disk Access, grant access to your \
                terminal app (Terminal, iTerm, Warp, Ghostty, etc.), then \
                fully quit the terminal (Cmd-Q) and relaunch it. Note: grant \
                FDA to the terminal, not to the pippin binary — macOS TCC \
                attaches the permission to the launching app.
                """,
                doctorCheck: "Voice Memos access"
            )
        case .databaseNotFound:
            return Remediation(
                humanHint: "Voice Memos database not found. Open the Voice Memos app once to initialize it.",
                doctorCheck: "Voice Memos access",
                shellCommand: "open -a \"Voice Memos\" && sleep 3"
            )
        case .notAvailable:
            return Remediation(
                humanHint: "mlx-audio is not installed. Install it with pipx so it lands in an isolated venv and pippin can find the entry-point binary.",
                doctorCheck: "mlx-audio",
                shellCommand: "pipx install mlx-audio"
            )
        }
    }

    /// Look up a remediation by snake_case error code. Returns `nil` when
    /// the code is not a registered `ErrorCategory`. Preserves the
    /// backward-compatible lookup shape used by `AgentError.from(_:)`.
    public static func forCode(_ code: String) -> Remediation? {
        ErrorCategory(rawValue: code).map(forCategory)
    }

    /// Resolve a remediation from any `Error` by first reducing it to an
    /// agent error code via `agentErrorCode(for:)`. Returns `nil` for
    /// uncatalogued errors.
    public static func forError(_ error: Error) -> Remediation? {
        forCode(agentErrorCode(for: error))
    }
}
