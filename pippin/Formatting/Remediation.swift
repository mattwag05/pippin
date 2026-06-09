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

public extension Remediation {
    /// Remediation for an EventKit/Contacts privacy permission that was not
    /// granted. These all collapse to the shared `access_denied` agent code, so
    /// the code-based `RemediationCatalog` can't tell them apart (it returns the
    /// Voice Memos Full Disk Access hint for every one). `RemediableError`
    /// conformances use this to supply the correct System Settings pane.
    ///
    /// - Parameters:
    ///   - permission: human label + System Settings pane (e.g. "Reminders").
    ///   - listCommand: a pippin command that triggers the first-use prompt.
    ///   - doctorCheck: matching `pippin doctor` check name.
    static func privacyAccess(
        permission: String,
        listCommand: String,
        doctorCheck: String
    ) -> Remediation {
        Remediation(
            humanHint: """
            \(permission) access is not granted. Open System Settings > Privacy \
            & Security > \(permission) and enable the app that launches pippin \
            (your terminal, or the agent/MCP client that spawns it) — macOS TCC \
            attaches the grant to the launching app, not the pippin binary. A \
            background agent (LaunchAgent) cannot show the first-use prompt, so \
            run `\(listCommand)` once from an interactive terminal to trigger it, \
            then re-run. Tip: `pippin permissions` resolves all promptable \
            permissions in one interactive pass.
            """,
            doctorCheck: doctorCheck
        )
    }

    /// Remediation for a Full Disk Access permission (Messages / Voice Memos
    /// read their SQLite DBs directly). Unlike EventKit/Contacts/Automation,
    /// FDA has no request API — there is no prompt to trigger, so `pippin
    /// permissions` can't resolve it; the user must toggle it manually and
    /// relaunch the launching app.
    static func fullDiskAccess(integration: String, listCommand: String) -> Remediation {
        Remediation(
            humanHint: """
            \(integration) needs Full Disk Access. Open System Settings > Privacy \
            & Security > Full Disk Access and enable the app that launches pippin \
            (your terminal — Terminal, iTerm, Warp, Ghostty — or the agent/MCP \
            client), then fully quit that app (Cmd-Q) and relaunch it. Full Disk \
            Access has no prompt, so `pippin permissions` cannot grant it for you. \
            Verify with `\(listCommand)`.
            """,
            doctorCheck: "\(integration) access"
        )
    }
}

/// An error that supplies its own structured remediation, taking precedence
/// over the code-based `RemediationCatalog` lookup in `AgentError.from(_:)`.
///
/// Needed because several distinct permission errors collapse to the same
/// snake_case code (`access_denied`): Reminders, Calendar, and Contacts each
/// require their own System Settings pane, not the Voice Memos Full Disk Access
/// hint the catalog returns for that shared code. Conformances return `nil` for
/// cases that should fall through to the catalog. (pippin-ci2)
public protocol RemediableError {
    var remediation: Remediation? { get }
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

    /// The single source of truth for "what's the remediation for this error?",
    /// shared by the agent-mode envelope (`AgentError.from`) and the human-mode
    /// CLI error path. An error's own typed remediation (`RemediableError`)
    /// wins over the code-based catalog, which can't disambiguate errors that
    /// share a snake_case code (e.g. the four `access_denied` cases — Reminders/
    /// Calendar/Contacts each need a different System Settings pane than Voice
    /// Memos' Full Disk Access). Both paths must call this so they can't drift
    /// apart again. (pippin-oxy)
    public static func resolve(for error: Error) -> Remediation? {
        (error as? RemediableError)?.remediation ?? forError(error)
    }
}
