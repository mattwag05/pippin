import Foundation

/// The one place outside the MCP server that launches a child process, drains
/// its output and enforces a deadline. osascript, node, the mlx-audio tools
/// and `get-secret` all run through it; each caller only decides what an exit
/// status, a signal or a timeout means for it.
enum Subprocess {
    struct Outcome {
        let stdout: Data
        let stderr: Data
        /// The exit status, or the signal number when `signaled` is true.
        let status: Int32
        /// The child died from a signal instead of exiting.
        let signaled: Bool
        /// The deadline passed while the child was still running, so this
        /// helper sent the signal. A signal from anywhere else is a crash.
        let timedOut: Bool

        var stdoutText: String {
            Self.trimmedText(stdout)
        }

        var stderrText: String {
            Self.trimmedText(stderr)
        }

        private static func trimmedText(_ data: Data) -> String {
            (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Launch `executable`, wait for it and return what it wrote.
    ///
    /// Both pipes are drained concurrently: a child that fills a 64 KB pipe
    /// buffer nobody is reading blocks forever. At `timeout` the child gets
    /// SIGTERM, and SIGKILL two seconds later if it is still alive.
    /// `discardStderr` sends stderr to /dev/null instead of capturing it.
    ///
    /// Throws only when the launch itself fails. A nonzero exit, a signal and
    /// a timeout are all reported in the `Outcome`.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval,
        discardStderr: Bool = false
    ) throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = discardStderr ? FileHandle.nullDevice : stderrPipe

        try process.run()

        // nonisolated(unsafe): each var is written once by one GCD block; group.wait() provides happens-before.
        nonisolated(unsafe) var stdoutData = Data()
        nonisolated(unsafe) var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        if !discardStderr {
            group.enter()
            DispatchQueue.global().async {
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        let killedByTimer = ConcurrentSlot<Bool>()
        let timeoutItem = DispatchWorkItem {
            guard process.isRunning else { return }
            killedByTimer.set(true)
            process.terminate() // SIGTERM: give the child 2 seconds to clean up
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        process.waitUntilExit()
        timeoutItem.cancel()
        group.wait()

        return Outcome(
            stdout: stdoutData,
            stderr: stderrData,
            status: process.terminationStatus,
            signaled: process.terminationReason == .uncaughtSignal,
            timedOut: killedByTimer.get() == true
        )
    }
}
