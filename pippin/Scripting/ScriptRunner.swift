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
/// to add a single auto-relaunch fallback when the host app is not running.
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

    /// Run a JXA script via `osascript -l JavaScript`. The script runs once
    /// unless the caller passes `idempotent: true` (a read, or a write that is
    /// safe to repeat): then a timeout with a non-nil `appName` invokes the
    /// launcher (typically `open -gja`) and re-runs the script exactly once.
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
        automationCheck: AutomationCheck = AutomationPermission.liveCheck
    ) throws -> String {
        if let automationBundleID,
           automationCheck(automationBundleID, PermissionPriming.canRequestAccess()) == .deny {
            throw ScriptRunnerError.automationDenied(automationBundleID)
        }
        do {
            return try runOsascript(script: script, timeoutSeconds: timeoutSeconds)
        } catch ScriptRunnerError.timeout {
            guard idempotent, let appName else { throw ScriptRunnerError.timeout }
            launcher(appName)
            return try runOsascript(script: script, timeoutSeconds: timeoutSeconds)
        }
    }

    private static func runOsascript(script: String, timeoutSeconds: Int) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ScriptRunnerError.launchFailed(error.localizedDescription)
        }

        // Drain both pipes concurrently to avoid deadlock on large output (>64KB pipe buffer).
        // nonisolated(unsafe): each var is written once by one GCD block; group.wait() provides happens-before.
        nonisolated(unsafe) var stdoutData = Data()
        nonisolated(unsafe) var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let killedByTimer = ConcurrentSlot<Bool>()
        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            killedByTimer.set(true)
            process.terminate() // SIGTERM — give osascript 2 seconds to clean up
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        // Only our own timer's kill is a timeout. Any other signal death is a
        // crash, which must not read as retryable.
        if process.terminationReason == .uncaughtSignal {
            if killedByTimer.get() == true { throw ScriptRunnerError.timeout }
            throw ScriptRunnerError.crashed(signal: process.terminationStatus)
        }

        let stdoutStr = (String(data: stdoutData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawStderr = (String(data: stderrData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw ScriptRunnerError.nonZeroExit(rawStderr)
        }

        // osascript can exit 0 and still write errors to stderr (e.g. TCC denial).
        // Filter benign framework log lines (timestamp-prefixed CoreData/NSDateFormatter noise)
        // before treating stderr as a script failure.
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
