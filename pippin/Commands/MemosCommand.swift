import ArgumentParser
import Foundation

public enum MemosError: LocalizedError {
    case binaryNotFound
    case failed(Int32, String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return """
                pippin-memos not found. Install it with:
                  cd pippin-memos && pipx install .
                """
        case .failed(let code, let detail):
            return "pippin-memos exited \(code): \(detail)"
        case .timeout:
            return "pippin-memos timed out"
        }
    }
}

public struct MemosCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "memos",
        abstract: "Interact with Voice Memos.",
        subcommands: [List.self, Info.self, Export.self, Delete.self]
    )

    public init() {}

    // MARK: - Subcommands

    public struct List: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all recordings as JSON."
        )

        @Option(name: .long, help: "Only return recordings on or after YYYY-MM-DD.")
        public var since: String?

        @Option(name: .long, help: "Output format: json (default) or text.")
        public var format: String = "json"

        public init() {}

        public mutating func run() async throws {
            var args = ["list", "--format", format]
            if let s = since { args += ["--since", s] }
            try runPippinMemos(args)
        }
    }

    public struct Info: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show full metadata for a single recording."
        )

        @Argument(help: "Memo UUID from `pippin memos list` output.")
        public var id: String

        public init() {}

        public mutating func run() async throws {
            try runPippinMemos(["info", id])
        }
    }

    public struct Export: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Copy recording(s) to a directory."
        )

        @Argument(help: "Memo UUID to export (omit with --all).")
        public var id: String?

        @Flag(name: .long, help: "Export every recording.")
        public var all: Bool = false

        @Option(name: .long, help: "Destination directory (created if absent).")
        public var output: String

        @Flag(name: .long, help: "Transcribe audio using parakeet-mlx and write .txt sidecar.")
        public var transcribe: Bool = false

        public init() {}

        public mutating func run() async throws {
            var args = ["export", "--output", output]
            if all {
                args.append("--all")
            } else if let id {
                args.append(id)
            } else {
                throw ValidationError("Provide a memo UUID or --all.")
            }
            if transcribe { args.append("--transcribe") }
            // Transcription can take several minutes; use a generous timeout
            let timeout = transcribe ? 600 : 10
            try runPippinMemos(args, timeoutSeconds: timeout)
        }
    }

    public struct Delete: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Move recording file to Trash. The DB row lingers until Voice Memos.app cleans up."
        )

        @Argument(help: "Memo UUID from `pippin memos list` output.")
        public var id: String

        @Flag(name: .long, help: "Print what would happen without moving to Trash.")
        public var dryRun: Bool = false

        public init() {}

        public mutating func run() async throws {
            var args = ["delete", id]
            if dryRun { args.append("--dry-run") }
            try runPippinMemos(args)
        }
    }
}

// MARK: - Runner

/// Find the pippin-memos binary: check known pipx path first, then PATH.
private func findPippinMemos() -> String? {
    let known = (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.local/bin/pippin-memos"
    if FileManager.default.isExecutableFile(atPath: known) {
        return known
    }
    // Fallback: search PATH via `which`
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    which.arguments = ["pippin-memos"]
    let pipe = Pipe()
    which.standardOutput = pipe
    which.standardError = Pipe()
    try? which.run()
    which.waitUntilExit()
    if which.terminationStatus == 0 {
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty { return out }
    }
    return nil
}

/// Run `pippin-memos <arguments>`, streaming stdout/stderr to our own handles.
func runPippinMemos(_ arguments: [String], timeoutSeconds: Int = 10) throws {
    guard let binary = findPippinMemos() else {
        throw MemosError.binaryNotFound
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    // Drain both pipes concurrently to avoid deadlock on large output (>64KB pipe buffer)
    var stdoutData = Data()
    var stderrData = Data()
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
        if process.isRunning { process.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: timeoutItem)

    process.waitUntilExit()
    timeoutItem.cancel()
    group.wait()

    if process.terminationReason == .uncaughtSignal {
        throw MemosError.timeout
    }

    // Forward stdout to our stdout
    if !stdoutData.isEmpty, let text = String(data: stdoutData, encoding: .utf8) {
        print(text, terminator: "")
    }

    guard process.terminationStatus == 0 else {
        let detail = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw MemosError.failed(process.terminationStatus, detail)
    }
}
