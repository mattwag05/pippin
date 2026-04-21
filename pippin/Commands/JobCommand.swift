import ArgumentParser
import Foundation

// MARK: - JobCommand

/// Run long `pippin` work in the background without tying up the caller's
/// process. `pippin job run -- <argv>` forks a detached child, returns a
/// `job_id`, and keeps going. Callers poll via `pippin job show`, or block
/// via `pippin job wait`.
public struct JobCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "job",
        abstract: "Manage background pippin jobs.",
        subcommands: [
            Run.self,
            Show.self,
            List.self,
            Wait.self,
            Logs.self,
            Gc.self,
        ]
    )

    public init() {}

    // MARK: Run

    public struct Run: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Fork a detached pippin sub-command; returns a job_id immediately.",
            discussion: """
            Use `--` to separate job flags from the sub-command:
                pippin job run -- mail index
                pippin job run -- memos summarize abc123 --provider ollama
            """
        )

        @Argument(parsing: .captureForPassthrough, help: "pippin argv to run (pass after `--`).")
        public var argv: [String] = []

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            // `captureForPassthrough` preserves the `--` terminator in the
            // captured array; strip it so the child sees clean argv.
            if argv.first == "--" { argv.removeFirst() }
            guard !argv.isEmpty else {
                throw ValidationError("pippin job run requires an argv — e.g. `pippin job run -- mail index`.")
            }
        }

        public mutating func run() async throws {
            let store = JobStore()
            try ensureRoot(store)
            let id = JobId.generate()
            try store.createDir(id)

            // Seed status.json before fork so `pippin job show <id>` is
            // immediately queryable even if the runner's own write races.
            var seed = Job(id: id, argv: argv, status: .running, startedAt: Date())
            try store.write(seed)

            let pippinPath = MCPServerRuntime.resolvePippinPath()
            let pid = try JobLauncher.launch(
                pippinPath: pippinPath,
                id: id,
                argv: argv,
                stdoutPath: store.stdoutPath(id),
                stderrPath: store.stderrPath(id)
            )
            seed.pid = pid
            try store.write(seed)

            if output.isAgent {
                try output.printAgent(seed)
            } else if output.isJSON {
                try printJSON(seed)
            } else {
                print("job_id: \(id)")
                print("pid:    \(pid)")
                print("status: running")
                print("tail logs: pippin job logs \(id) --stream")
            }
        }
    }

    // MARK: Show

    public struct Show: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a job's status + stdout/stderr tails."
        )

        @Argument(help: "Job id or unambiguous prefix.")
        public var id: String

        @Option(name: .long, help: "Bytes of stdout to include (default: 4096).")
        public var tail: Int = 4096

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let store = JobStore()
            let job = try store.read(id)
            let stdoutTail = store.tailStdout(job.id, maxBytes: max(0, tail))
            let stderrTail = store.tailStderr(job.id, maxBytes: max(0, tail))
            let view = JobView(job: job, stdoutTail: stdoutTail, stderrTail: stderrTail)
            if output.isAgent {
                try output.printAgent(view)
            } else if output.isJSON {
                try printJSON(view)
            } else {
                printJobHeader(job)
                if !stdoutTail.isEmpty {
                    print("— stdout (tail \(stdoutTail.count)B) —")
                    print(stdoutTail)
                }
                if !stderrTail.isEmpty {
                    print("— stderr (tail \(stderrTail.count)B) —")
                    print(stderrTail)
                }
            }
        }
    }

    // MARK: List

    public struct List: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List recent jobs (default: 20 most recent)."
        )

        @Option(name: .long, help: "Maximum jobs to return (default: 20).")
        public var limit: Int = 20

        @Option(name: .long, help: "Filter by status: running, done, error, killed.")
        public var status: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit > 0 else { throw ValidationError("--limit must be positive.") }
            if let s = status, JobStatus(rawValue: s) == nil {
                throw ValidationError("--status must be one of: running, done, error, killed.")
            }
        }

        public mutating func run() async throws {
            let store = JobStore()
            var jobs = store.all().sorted { $0.startedAt > $1.startedAt }
            if let filter = status.flatMap({ JobStatus(rawValue: $0) }) {
                jobs = jobs.filter { $0.status == filter }
            }
            jobs = Array(jobs.prefix(limit))
            if output.isAgent {
                try output.printAgent(jobs)
            } else if output.isJSON {
                try printJSON(jobs)
            } else {
                if jobs.isEmpty {
                    print("No jobs.")
                } else {
                    for job in jobs {
                        printJobLine(job)
                    }
                }
            }
        }
    }

    // MARK: Wait

    public struct Wait: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "wait",
            abstract: "Block until a job reaches a terminal state, then print its status."
        )

        @Argument(help: "Job id or unambiguous prefix.")
        public var id: String

        @Option(name: .long, help: "Maximum seconds to wait (default: 300). 0 for unbounded.")
        public var timeout: Int = 300

        @Option(name: .long, help: "Poll interval in milliseconds (default: 200).")
        public var pollMs: Int = 200

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let store = JobStore()
            let deadline: Date? = timeout > 0 ? Date().addingTimeInterval(Double(timeout)) : nil
            let pollDelayNs = UInt64(max(10, pollMs)) * 1_000_000

            while true {
                let job = try store.read(id)
                if job.status.isTerminal {
                    if output.isAgent {
                        try output.printAgent(job)
                    } else if output.isJSON {
                        try printJSON(job)
                    } else {
                        printJobHeader(job)
                    }
                    return
                }
                if let deadline, Date() >= deadline {
                    throw JobCommandError.waitTimedOut(job.id, timeoutSeconds: timeout)
                }
                try? await Task.sleep(nanoseconds: pollDelayNs)
            }
        }
    }

    // MARK: Logs

    public struct Logs: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "logs",
            abstract: "Print a job's stdout/stderr; --stream to tail until terminal."
        )

        @Argument(help: "Job id or unambiguous prefix.")
        public var id: String

        @Flag(name: .long, help: "Tail until the job reaches a terminal state.")
        public var stream: Bool = false

        @Option(name: .long, help: "Stream poll interval in milliseconds (default: 200).")
        public var pollMs: Int = 200

        @Flag(name: .long, help: "Read stderr instead of stdout.")
        public var stderr: Bool = false

        public init() {}

        public mutating func run() async throws {
            let store = JobStore()
            let resolved = try store.resolve(id)
            let path = stderr ? store.stderrPath(resolved) : store.stdoutPath(resolved)
            if !stream {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                   let text = String(data: data, encoding: .utf8)
                {
                    print(text, terminator: "")
                }
                return
            }
            // Streaming tail: seek to end? Start at beginning for the first
            // call — agents expect the full history.
            var offset: UInt64 = 0
            let pollDelayNs = UInt64(max(10, pollMs)) * 1_000_000
            while true {
                offset += printNewBytes(path: path, from: offset)
                let job = try store.read(resolved)
                if job.status.isTerminal {
                    _ = printNewBytes(path: path, from: offset)
                    return
                }
                try? await Task.sleep(nanoseconds: pollDelayNs)
            }
        }

        /// Append any new bytes at `path` past `from` to stdout; return the
        /// number of bytes consumed so the caller can advance its cursor.
        private func printNewBytes(path: String, from: UInt64) -> UInt64 {
            guard let handle = FileHandle(forReadingAtPath: path) else { return 0 }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            guard size > from else { return 0 }
            try? handle.seek(toOffset: from)
            let data = handle.readDataToEndOfFile()
            FileHandle.standardOutput.write(data)
            return UInt64(data.count)
        }
    }

    // MARK: Gc

    public struct Gc: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "gc",
            abstract: "Prune terminal jobs older than --older-than (default: 7d)."
        )

        @Option(
            name: .customLong("older-than"),
            help: "Cutoff age: number + d/h/m (default: 7d)."
        )
        public var olderThan: String = "7d"

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let seconds = try parseDuration(olderThan)
            let cutoff = Date().addingTimeInterval(-Double(seconds))
            let store = JobStore()
            let removed = try store.gc(olderThan: cutoff)
            let result = GcResult(removed: removed, cutoff: cutoff)
            if output.isAgent {
                try output.printAgent(result)
            } else if output.isJSON {
                try printJSON(result)
            } else {
                if removed.isEmpty {
                    print("No jobs older than \(olderThan).")
                } else {
                    for id in removed {
                        print("removed \(id)")
                    }
                }
            }
        }
    }
}

// MARK: - JobRunnerInternalCommand

/// Hidden sub-command invoked by `pippin job run`. Forks the actual pippin
/// argv, waits for it, and records terminal state in status.json. Separated
/// so status-file writes never run in the user-facing `pippin` code path
/// (the CLI process exits 0 immediately after launching this).
public struct JobRunnerInternalCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "job-runner-internal",
        abstract: "Internal — do not call directly. Executes a detached job and updates status.json.",
        shouldDisplay: false
    )

    @Argument(help: "Job id.")
    public var id: String

    @Argument(parsing: .captureForPassthrough, help: "pippin argv to run.")
    public var argv: [String] = []

    public init() {}

    public mutating func run() async throws {
        if argv.first == "--" { argv.removeFirst() }
        let store = JobStore()
        var job = try store.read(id)

        let pippinPath = MCPServerRuntime.resolvePippinPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pippinPath)
        process.arguments = argv
        // stdout/stderr were already redirected to the log files by the
        // parent (via fileHandle dup). Let the inner process inherit — its
        // bytes will land in the same file.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            job.status = .error
            job.exitCode = -1
            job.endedAt = Date()
            job.durationMs = Int(job.endedAt!.timeIntervalSince(job.startedAt) * 1000)
            try? store.write(job)
            Darwin.exit(1)
        }

        process.waitUntilExit()

        let endedAt = Date()
        job.endedAt = endedAt
        job.durationMs = Int(endedAt.timeIntervalSince(job.startedAt) * 1000)
        job.exitCode = process.terminationStatus
        switch process.terminationReason {
        case .exit:
            job.status = process.terminationStatus == 0 ? .done : .error
        case .uncaughtSignal:
            job.status = .killed
        @unknown default:
            job.status = .error
        }
        try? store.write(job)
        Darwin.exit(process.terminationStatus)
    }
}

// MARK: - JobLauncher

/// Detached-process launcher. Redirects stdout/stderr to the per-job log
/// files via append-mode FileHandles so the runner-internal (and its child)
/// can inherit them transparently.
enum JobLauncher {
    static func launch(
        pippinPath: String,
        id: String,
        argv: [String],
        stdoutPath: String,
        stderrPath: String
    ) throws -> Int32 {
        let stdoutHandle = try openAppend(stdoutPath)
        let stderrHandle = try openAppend(stderrPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pippinPath)
        process.arguments = ["job-runner-internal", id, "--"] + argv
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            throw JobCommandError.launchFailed(error.localizedDescription)
        }
        // Close our copies — the child keeps its own fds open.
        try? stdoutHandle.close()
        try? stderrHandle.close()
        return process.processIdentifier
    }

    private static func openAppend(_ path: String) throws -> FileHandle {
        FileManager.default.createFile(atPath: path, contents: nil)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw JobCommandError.launchFailed("could not open \(path) for appending")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

// MARK: - Errors

public enum JobCommandError: LocalizedError {
    case launchFailed(String)
    case waitTimedOut(String, timeoutSeconds: Int)
    case invalidDuration(String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(detail):
            return "Failed to launch job: \(detail)"
        case let .waitTimedOut(id, seconds):
            return "Job \(id) did not reach a terminal state within \(seconds)s."
        case let .invalidDuration(input):
            return "Could not parse duration '\(input)'. Expected a number followed by d, h, or m (e.g. 7d)."
        }
    }
}

// MARK: - Views

/// Output shape for `pippin job show` — adds log tails to the base Job.
public struct JobView: Encodable, Sendable {
    public let job: Job
    public let stdoutTail: String
    public let stderrTail: String

    enum CodingKeys: String, CodingKey {
        case v, id, argv, pid, status
        case exitCode = "exit_code"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMs = "duration_ms"
        case stdoutTail = "stdout_tail"
        case stderrTail = "stderr_tail"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(job.v, forKey: .v)
        try container.encode(job.id, forKey: .id)
        try container.encode(job.argv, forKey: .argv)
        try container.encodeIfPresent(job.pid, forKey: .pid)
        try container.encode(job.status, forKey: .status)
        try container.encodeIfPresent(job.exitCode, forKey: .exitCode)
        try container.encode(job.startedAt, forKey: .startedAt)
        try container.encodeIfPresent(job.endedAt, forKey: .endedAt)
        try container.encodeIfPresent(job.durationMs, forKey: .durationMs)
        try container.encode(stdoutTail, forKey: .stdoutTail)
        try container.encode(stderrTail, forKey: .stderrTail)
    }
}

public struct GcResult: Encodable, Sendable {
    public let removed: [String]
    public let cutoff: Date

    enum CodingKeys: String, CodingKey {
        case removed, cutoff
    }
}

// MARK: - Helpers

private func ensureRoot(_ store: JobStore) throws {
    try? FileManager.default.createDirectory(
        atPath: store.root, withIntermediateDirectories: true
    )
}

/// Parse "7d" / "12h" / "30m" / "2w" into seconds. Used by `job gc
/// --older-than`.
func parseDuration(_ input: String) throws -> Int {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    guard let unitChar = trimmed.last else {
        throw JobCommandError.invalidDuration(input)
    }
    let numberPart = String(trimmed.dropLast())
    guard let value = Int(numberPart), value >= 0 else {
        throw JobCommandError.invalidDuration(input)
    }
    switch unitChar {
    case "s", "S": return value
    case "m", "M": return value * 60
    case "h", "H": return value * 3600
    case "d", "D": return value * 86400
    case "w", "W": return value * 86400 * 7
    default: throw JobCommandError.invalidDuration(input)
    }
}

private func printJobHeader(_ job: Job) {
    print("job_id:     \(job.id)")
    print("status:     \(job.status.rawValue)")
    print("argv:       \(job.argv.joined(separator: " "))")
    if let pid = job.pid { print("pid:        \(pid)") }
    print("started:    \(ISO8601DateFormatter().string(from: job.startedAt))")
    if let endedAt = job.endedAt {
        print("ended:      \(ISO8601DateFormatter().string(from: endedAt))")
    }
    if let exitCode = job.exitCode { print("exit_code:  \(exitCode)") }
    if let durationMs = job.durationMs { print("duration:   \(durationMs)ms") }
}

private func printJobLine(_ job: Job) {
    let shortId = String(job.id.prefix(12))
    let statusStr = job.status.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
    let argvStr = job.argv.joined(separator: " ")
    let when = ISO8601DateFormatter().string(from: job.startedAt)
    print("\(shortId)  \(statusStr)  \(when)  \(argvStr)")
}
