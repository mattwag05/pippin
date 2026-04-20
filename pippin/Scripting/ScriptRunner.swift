import Foundation

/// Errors emitted by `ScriptRunner.run`. Bridges translate these to their own
/// typed errors (NotesBridgeError, MailBridgeError, etc.) for user-facing messages.
public enum ScriptRunnerError: Error, Sendable {
    case timeout
    case nonZeroExit(String) // raw stderr when osascript exits non-zero
    case stderrOnSuccess(String) // filtered stderr lines emitted even when exit=0 (e.g. TCC denial)
    case launchFailed(String) // process.run() threw before osascript started
}

/// Shared osascript runner used by NotesBridge and MailBridge. Extracted to
/// centralize the concurrent pipe-drain + SIGTERM/SIGKILL timeout pattern and
/// to add a single auto-relaunch fallback when the host app is not running.
public enum ScriptRunner {
    public typealias AppLauncher = @Sendable (String) -> Void

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

    /// Run a JXA script via `osascript -l JavaScript`. If the run times out and
    /// `appName` is non-nil, the launcher is invoked (typically `open -gja`) and
    /// the script is retried exactly once. Any further timeout is fatal.
    public static func run(
        _ script: String,
        timeoutSeconds: Int,
        appName: String? = nil,
        launcher: AppLauncher = defaultAppLauncher
    ) throws -> String {
        do {
            return try runOsascript(script: script, timeoutSeconds: timeoutSeconds)
        } catch ScriptRunnerError.timeout {
            guard let appName else { throw ScriptRunnerError.timeout }
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

        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate() // SIGTERM — give osascript 2 seconds to clean up
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        if process.terminationReason == .uncaughtSignal {
            throw ScriptRunnerError.timeout
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
