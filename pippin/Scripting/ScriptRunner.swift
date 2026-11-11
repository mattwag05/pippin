import Foundation

/// Errors emitted by `ScriptRunner.run`. Bridges translate these to their own
/// typed errors (NotesBridgeError, MailBridgeError, etc.) for user-facing messages.
public enum ScriptRunnerError: Error, Sendable {
    case timeout // killed by our own timer, and only that
    /// A script that is not safe to run twice hit the timer, so the change may
    /// or may not have been applied. Bridges throw this in place of `.timeout`
    /// for their non-idempotent scripts.
    case outcomeUnknown(app: String)
    case crashed(signal: Int32) // osascript died on a signal we did not send
    case nonZeroExit(String) // raw stderr when osascript exits non-zero
    case stderrOnSuccess(String) // filtered stderr lines emitted even when exit=0 (e.g. TCC denial)
    case launchFailed(String) // process.run() threw before osascript started
    case automationDenied(String) // Automation (Apple Events) not authorized for the target bundle id (pippin-qjf)
}

extension ScriptRunnerError: RemediableError {
    public var agentCode: String {
        switch self {
        case .timeout: return "timeout"
        case .outcomeUnknown: return "outcome_unknown"
        case .crashed: return "script_crashed"
        case .nonZeroExit: return "non_zero_exit"
        case .stderrOnSuccess: return "stderr_on_success"
        case .launchFailed: return "launch_failed"
        case .automationDenied: return "automation_denied"
        }
    }

    public var nextStep: NextStep {
        switch self {
        case .timeout: return .retry(after: 5)
        case let .outcomeUnknown(app):
            // Not retryable: look at the current state first.
            let group = app.lowercased()
            return .call(tool: "\(group)_list", argv: [group, "list"])
        case .crashed, .nonZeroExit, .stderrOnSuccess, .launchFailed:
            return .call(tool: "doctor", argv: ["doctor"])
        case .automationDenied:
            return .human("Run `pippin permissions` in a terminal and approve Automation control of the target app.")
        }
    }
}

extension ScriptRunnerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timeout: return "The automation script timed out."
        case let .outcomeUnknown(app):
            return "The \(app) change timed out and may or may not have been applied. Check the current state before repeating it."
        case let .crashed(signal): return "osascript crashed with signal \(signal)."
        case let .nonZeroExit(msg), let .stderrOnSuccess(msg): return "Automation script failed: \(msg.prefix(200))"
        case let .launchFailed(msg): return "osascript launch failed: \(msg)"
        case let .automationDenied(bundleID): return "Automation is not authorized for \(bundleID)."
        }
    }
}

/// Shared osascript runner used by NotesBridge and MailBridge. Extracted to
/// centralize the concurrent pipe-drain + SIGTERM/SIGKILL timeout pattern and
/// the launch of a host app that is not running.
public enum ScriptRunner {
    public typealias AppLauncher = @Sendable (String) -> Void

    /// Pre-flight Automation check: `(bundleID, canPrompt) -> Decision`. Injected
    /// for testability; defaults to the live `AEDeterminePermissionToAutomateTarget`
    /// probe. `canPrompt` mirrors `PermissionPriming.canRequestAccess()`.
    public typealias AutomationCheck = @Sendable (String, Bool) -> AutomationPermission.Decision

    /// Default launcher: `/usr/bin/open -gja <appName>` with a 3-second wait
    /// cap, followed by a short settle sleep so scripting targets register.
    public static let defaultAppLauncher: AppLauncher = { appName in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-gja", appName]
        do {
            try proc.run()
        } catch {
            return
        }
        let deadline = Date().addingTimeInterval(3)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning { proc.terminate() }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Under MCP the server kills the whole command at 60s
    /// (`MCPServerRuntime.defaultChildTimeoutSeconds`), so every script the
    /// process runs shares one deadline 5s short of that.
    static let mcpCommandBudgetSeconds: TimeInterval = 55

    private static let processStart = ProcessTable.startTime(of: getpid()) ?? Date()

    /// Seconds a script may run: the caller's cap, and under MCP no more than
    /// what is left of the command's budget.
    static func budget(requested: Int, underMCP: Bool, elapsed: TimeInterval) -> TimeInterval {
        let requested = TimeInterval(requested)
        return underMCP ? min(requested, mcpCommandBudgetSeconds - elapsed) : requested
    }

    /// Run a JXA script via `osascript -l JavaScript`, exactly once, within
    /// `timeoutSeconds`. With `idempotent: true` (a read, or a write that is
    /// safe to repeat) and a non-nil `appName`, an app that is not running is
    /// launched first (typically `open -gja`), inside the same deadline. That
    /// replaces the old run, time out, relaunch, run again sequence, which
    /// took twice the timeout and ran the script twice.
    /// A caller whose script is not idempotent must report its `.timeout` as
    /// `.outcomeUnknown`, never as retryable.
    ///
    /// When `automationBundleID` is non-nil, an `AEDeterminePermissionToAutomateTarget`
    /// pre-check runs first: if Automation is denied (or undetermined and we can't
    /// prompt), the call fast-fails with `.automationDenied` instead of letting
    /// `osascript` block to the soft-timeout. The check prompts only when a user
    /// is at a TTY (`PermissionPriming.canRequestAccess()`), so interactive use
    /// self-heals on first call. (pippin-qjf)
    public static func run(
        _ script: String,
        timeoutSeconds: Int,
        appName: String? = nil,
        idempotent: Bool = false,
        automationBundleID: String? = nil,
        launcher: AppLauncher = defaultAppLauncher,
        automationCheck: AutomationCheck = AutomationPermission.liveCheck,
        isAppRunning: @Sendable (String) -> Bool = ProcessTable.isRunning(named:),
        underMCP: Bool = isMCPContext()
    ) throws -> String {
        if let automationBundleID,
           automationCheck(automationBundleID, PermissionPriming.canRequestAccess()) == .deny {
            throw ScriptRunnerError.automationDenied(automationBundleID)
        }
        let started = Date()
        let total = budget(
            requested: timeoutSeconds, underMCP: underMCP, elapsed: started.timeIntervalSince(processStart)
        )
        if idempotent, let appName, total > 0, !isAppRunning(appName) {
            launcher(appName)
        }
        let remaining = total - Date().timeIntervalSince(started)
        guard remaining > 0 else { throw ScriptRunnerError.timeout }
        return try runOsascript(script: script, timeout: remaining)
    }

    private static func runOsascript(script: String, timeout: TimeInterval) throws -> String {
        let outcome: Subprocess.Outcome
        do {
            outcome = try Subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                // The script goes in on stdin, not `-e`: it can hold mail or
                // note text, and argv is readable by any local user via `ps`.
                arguments: ["-l", "JavaScript"],
                input: Data(script.utf8),
                timeout: timeout
            )
        } catch {
            throw ScriptRunnerError.launchFailed(error.localizedDescription)
        }

        // Only our own timer's kill is a timeout. Any other signal death is a
        // crash, which must not read as retryable.
        if outcome.signaled {
            if outcome.timedOut { throw ScriptRunnerError.timeout }
            throw ScriptRunnerError.crashed(signal: outcome.status)
        }

        let stdoutStr = outcome.stdoutText
        let rawStderr = outcome.stderrText

        guard outcome.status == 0 else {
            throw ScriptRunnerError.nonZeroExit(rawStderr)
        }

        // Exit status decides success; stderr on a zero exit is noise (JXA
        // `console.log` writes there) and must not fail a script that ran, least
        // of all a send that may then be repeated. The one exception is a zero
        // exit with no output at all and real errors on stderr (e.g. TCC denial),
        // where the stderr text is the only explanation of the empty result.
        // Benign framework log lines (timestamp-prefixed CoreData noise) are
        // filtered first.
        guard stdoutStr.isEmpty else { return stdoutStr }
        let errorLines = rawStderr
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return false }
                let looksLikeLogLine = trimmed.first?.isNumber == true && trimmed.contains("osascript[")
                return !looksLikeLogLine
            }
        if !errorLines.isEmpty {
            throw ScriptRunnerError.stderrOnSuccess(errorLines.joined(separator: "\n"))
        }

        return stdoutStr
    }
}

/// Decode JSON emitted by an osascript bridge script. Failures route through
/// `makeError` so each bridge keeps its own typed decoding error.
public func decodeScriptJSON<T: Decodable>(_ type: T.Type, from json: String, makeError: (String) -> some Error) throws -> T {
    guard !json.isEmpty else {
        throw makeError("osascript returned empty output — possible TCC denial")
    }
    guard let data = json.data(using: .utf8) else {
        throw makeError("Non-UTF8 output")
    }
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw makeError(error.localizedDescription)
    }
}
