import ArgumentParser
import Foundation

/// Execute a JSON array of pippin sub-commands concurrently as child processes,
/// returning their per-item agent envelopes wrapped in a single outer envelope.
///
/// The MCP companion tool `batch` is the real unlock — MCP serializes tool
/// calls one at a time, so a single `batch` call is the only way to fan out.
public struct BatchCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Execute multiple pippin commands concurrently from a JSON array.",
        discussion: """
        Reads a JSON array of `{cmd, args}` entries from stdin (or from --entries / --input),
        runs each as a child `pippin` process with `--format agent`, and returns an array
        of per-item envelopes inside one outer envelope.

        Example (stdin):
          echo '[{"cmd":"calendar","args":["today"]},
                 {"cmd":"reminders","args":["lists"]}]' | pippin batch --format agent
        """
    )

    @Option(name: .long, help: "Maximum concurrent sub-commands (default: 4).")
    public var concurrency: Int = 4

    @Option(name: .long, help: "Read entries from this file instead of stdin.")
    public var input: String?

    @Option(name: .long, help: "Inline JSON array of entries (alternative to stdin / --input).")
    public var entries: String?

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func validate() throws {
        guard concurrency > 0 else {
            throw ValidationError("--concurrency must be positive.")
        }
    }

    public mutating func run() async throws {
        let parsed = try Self.readEntries(entries: entries, input: input)
        let pippinPath = MCPServerRuntime.resolvePippinPath()
        let results = await Self.dispatch(
            entries: parsed,
            concurrency: concurrency,
            pippinPath: pippinPath
        )

        if output.isAgent {
            try output.printAgent(results)
        } else if output.isJSON {
            try printJSON(results)
        } else {
            let okCount = results.filter { Self.statusString($0) == "ok" }.count
            let errCount = results.count - okCount
            print("Batch: \(results.count) entries (\(okCount) ok, \(errCount) error)")
        }
    }

    // MARK: - Helpers

    static func readEntries(entries: String?, input: String?) throws -> [BatchEntry] {
        let data: Data
        if let entries {
            data = Data(entries.utf8)
        } else if let path = input {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw BatchError.emptyInput
        }
        do {
            return try JSONDecoder().decode([BatchEntry].self, from: Data(trimmed.utf8))
        } catch {
            throw BatchError.invalidEntriesJSON(error.localizedDescription)
        }
    }

    static func dispatch(
        entries: [BatchEntry],
        concurrency: Int,
        pippinPath: String
    ) async -> [JSONValue] {
        guard !entries.isEmpty else { return [] }
        let lane = max(1, min(concurrency, entries.count))

        return await withTaskGroup(of: (Int, JSONValue).self, returning: [JSONValue].self) { group in
            var nextIndex = 0
            for index in 0 ..< lane {
                let entry = entries[index]
                group.addTask {
                    let result = runOne(entry: entry, pippinPath: pippinPath)
                    return (index, result)
                }
            }
            nextIndex = lane

            var collected: [(Int, JSONValue)] = []
            while let value = await group.next() {
                collected.append(value)
                if nextIndex < entries.count {
                    let index = nextIndex
                    let entry = entries[index]
                    group.addTask {
                        let result = runOne(entry: entry, pippinPath: pippinPath)
                        return (index, result)
                    }
                    nextIndex += 1
                }
            }
            return collected
                .sorted(by: { $0.0 < $1.0 })
                .map { $0.1 }
        }
    }

    static func runOne(entry: BatchEntry, pippinPath: String) -> JSONValue {
        let argv = entry.resolvedArgv
        do {
            let result = try MCPServerRuntime.runChild(argv: argv, pippinPath: pippinPath)
            let stdoutText = String(data: result.stdout, encoding: .utf8) ?? ""
            let trimmed = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return entryEnvelopeError(
                    code: .emptyOutput,
                    message: "Child produced no output (exit \(result.exitCode))"
                )
            }
            if let json = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) {
                return json
            }
            return entryEnvelopeError(
                code: .invalidJSON,
                message: "Child stdout was not valid JSON: \(String(trimmed.prefix(200)))"
            )
        } catch {
            return entryEnvelopeError(
                code: .childLaunchFailed,
                message: error.localizedDescription
            )
        }
    }

    /// Build an envelope-shaped JSON for a per-entry failure that happened in
    /// the parent process. Routes through `AgentErrorEnvelope` so the shape
    /// can't drift from the canonical `--format agent` envelope.
    static func entryEnvelopeError(code: BatchEntryErrorCode, message: String) -> JSONValue {
        let payload = AgentError(code: code.rawValue, message: message).error
        let envelope = AgentErrorEnvelope(
            v: AGENT_SCHEMA_VERSION,
            status: "error",
            durationMs: 0,
            error: payload
        )
        guard
            let data = try? JSONEncoder().encode(envelope),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return .object(["status": .string("error")])
        }
        return value
    }

    static func statusString(_ envelope: JSONValue) -> String? {
        envelope["status"]?.stringValue
    }
}

// MARK: - Error codes

/// Snake-case error codes emitted in per-entry envelopes when the parent
/// process couldn't run or read the child. Sub-command-level errors come
/// straight from each child's own `printAgentError` and are passed through.
public enum BatchEntryErrorCode: String, Sendable {
    case emptyOutput = "empty_output"
    case invalidJSON = "invalid_json"
    case childLaunchFailed = "child_launch_failed"
}

// MARK: - Entry decoding

/// One row of the batch input array.
public struct BatchEntry: Decodable, Equatable, Sendable {
    public let cmd: String
    public let args: [String]?

    public init(cmd: String, args: [String]? = nil) {
        self.cmd = cmd
        self.args = args
    }

    /// Final argv passed to the child `pippin` process. Always ends with
    /// `--format agent` so children produce envelope JSON. If the caller
    /// already supplied --format, we don't double-add it.
    public var resolvedArgv: [String] {
        var argv = [cmd]
        if let args { argv.append(contentsOf: args) }
        if !argv.contains("--format") {
            argv.append("--format")
            argv.append("agent")
        }
        return argv
    }
}

// MARK: - Errors

public enum BatchError: LocalizedError {
    case emptyInput
    case invalidEntriesJSON(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "pippin batch: no input — provide a JSON array via stdin, --input, or --entries."
        case let .invalidEntriesJSON(detail):
            return "pippin batch: input was not a valid JSON array of {cmd, args} entries: \(detail)"
        }
    }
}
