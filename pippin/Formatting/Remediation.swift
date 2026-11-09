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
            \(permission) access is not granted. By default pippin relaunches \
            itself as its own responsible process, so macOS TCC attaches the \
            grant to pippin itself at its installed path (for example \
            ~/.local/bin/pippin), not to the terminal or agent that launches it. \
            Run `pippin permissions` once from an interactive terminal to approve \
            it, or enable pippin under System Settings > Privacy & Security > \
            \(permission). A background agent (LaunchAgent) cannot show the \
            first-use prompt, so grant it interactively (or run `\(listCommand)` \
            once in a terminal), then re-run. Exception: with \
            PIPPIN_NO_DISCLAIM=1, or when the disclaimed relaunch is unavailable, \
            the grant attaches to the launching app (your terminal, or the \
            agent/MCP client) instead.
            """,
            doctorCheck: doctorCheck
        )
    }

    /// Remediation for an Automation (Apple Events) grant that pippin's own
    /// (disclaimed) identity is missing for a scripting target (Mail/Notes/
    /// Messages). Like the privacy permissions this collapses to the shared
    /// `access_denied` code, so the emitting error conforms to `RemediableError`
    /// and returns this to point at the Automation pane rather than the Voice
    /// Memos Full Disk Access hint the code-based catalog would supply. (pippin-qjf)
    ///
    /// - Parameters:
    ///   - app: the scripting target app, e.g. "Mail".
    ///   - trigger: a pippin command that drives this target, run once from an
    ///     interactive terminal to surface the Automation prompt.
    static func automationAccess(app: String, trigger: String) -> Remediation {
        Remediation(
            humanHint: """
            pippin is not authorized to control \(app) via Automation (Apple \
            Events). Run `\(trigger)` once from an interactive terminal to \
            trigger the macOS Automation prompt and click OK, or enable it under \
            System Settings > Privacy & Security > Automation. Background \
            agents/MCP clients can't show the prompt, so grant it interactively \
            once, then re-run.
            """,
            doctorCheck: "\(app) access"
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

/// A call the agent can make next to recover or learn more. `tool` is an MCP
/// tool name, `args` its arguments, and `argv` the same call for CLI callers.
public struct NextCall: Codable, Sendable, Equatable {
    public let tool: String
    public let args: [String: String]
    public let argv: [String]

    public init(tool: String, args: [String: String] = [:], argv: [String]) {
        self.tool = tool
        self.args = args
        self.argv = argv
    }
}

/// What a caller should do about a failure, as fields it can act on directly
/// (pippin-pxz9). `humanAction` is set when no agent can fix it.
public struct NextStep: Codable, Sendable, Equatable {
    public let retryable: Bool
    public let retryAfterSeconds: Int?
    public let nextCall: NextCall?
    public let humanAction: String?

    public init(
        retryable: Bool = false,
        retryAfterSeconds: Int? = nil,
        nextCall: NextCall? = nil,
        humanAction: String? = nil
    ) {
        self.retryable = retryable
        self.retryAfterSeconds = retryAfterSeconds
        self.nextCall = nextCall
        self.humanAction = humanAction
    }

    private enum CodingKeys: String, CodingKey {
        case retryable
        case retryAfterSeconds = "retry_after_seconds"
        case nextCall = "next_call"
        case humanAction = "human_action"
    }

    /// Nothing further to do: the input or the request has to change.
    public static let none = NextStep()

    public static func retry(after seconds: Int? = nil) -> NextStep {
        NextStep(retryable: true, retryAfterSeconds: seconds)
    }

    public static func call(tool: String, args: [String: String] = [:], argv: [String]) -> NextStep {
        NextStep(nextCall: NextCall(tool: tool, args: args, argv: argv))
    }

    public static func human(_ action: String) -> NextStep {
        NextStep(humanAction: action)
    }

    /// For failures with no authored step (ArgumentParser, foreign errors):
    /// retryability follows the exit class.
    static func derived(fromCode code: String) -> NextStep {
        NextStep(retryable: PippinExitCode.classify(code) == 7)
    }
}

/// An error that states its own fixed code and next step, authored by the
/// module where the raw failure happens, since one code such as `access_denied`
/// needs a different fix per app. Neither has a default, so a new case cannot
/// compile without deciding both.
///
/// `remediation` supplies human-facing fix text and takes precedence over the
/// code-based `RemediationCatalog`; it defaults to `nil` (catalog lookup).
public protocol RemediableError: Error {
    /// The stable snake_case code. Renaming a Swift case does not change it.
    var agentCode: String { get }
    var nextStep: NextStep { get }
    var remediation: Remediation? { get }
}

public extension RemediableError {
    var remediation: Remediation? { nil }
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
