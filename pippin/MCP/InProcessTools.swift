import ArgumentParser
import Foundation

/// In-process execution for the safe read-only MCP tools: EventKit
/// (Calendar/Reminders), CNContactStore (Contacts), chat.db (Messages) and
/// Notes reads. These run the same `AgentCommand` the CLI runs, parsed from the
/// same argv a child would get, so the two paths cannot drift. Notes reads are
/// JXA, but the script runs in an `osascript` child with its own hard kill
/// (`ScriptRunner`), and the Automation pre-check cannot prompt here (stdin is
/// not a TTY), so nothing in this process blocks on Notes. Saving the `pippin`
/// child start is what makes a warm Notes read faster (pippin-ai5s). Everything
/// else wedge-prone (Mail JXA, AI, browser, audio) and all writes stay on the
/// child path, where a hard kill exists: a blocking framework call in this
/// process can only be abandoned, never killed.
enum MCPInProcessTools {
    /// Parses only what runs in-process; PippinLib cannot see the real root.
    private struct InProcessRoot: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pippin",
            subcommands: [CalendarCommand.self, RemindersCommand.self, ContactsCommand.self, MessagesCommand.self, NotesCommand.self, MailCommand.self]
        )
    }

    /// Longest a call may hold the serial JSON-RPC loop. Above the 15s EventKit
    /// caps; Contacts name and id fetches have no cap of their own, so this is
    /// what bounds a stalled contactsd.
    static let deadlineSeconds = 25

    /// Thrown by an in-process handler for a call it should not take; the
    /// dispatcher runs the child instead.
    struct UseChildPath: Error {}

    /// Mail reads answer from Mail's on-disk index in milliseconds, and the
    /// accounts list is one short script (pippin-k177). Calls that fetch or
    /// scan bodies, or ask an embedding provider, can run for many seconds,
    /// so they keep the child path and its hard kill.
    static func executeMailRead(_ argv: [String]) async throws -> String {
        let slow = argv.contains { $0 == "--body" || $0 == "--semantic" || ($0.hasPrefix("--preview=") && $0 != "--preview=0") }
        if slow { throw UseChildPath() }
        return try await execute(argv)
    }

    /// The command `argv` names, if it is one that runs in-process.
    static func parse(_ argv: [String]) throws -> any AgentCommand {
        guard let command = try InProcessRoot.parseAsRoot(argv) as? any AgentCommand else {
            throw MCPServerRuntimeError.notInProcessCapable(argv.joined(separator: " "))
        }
        return command
    }

    /// Parse `argv` and run the command, returning its envelope.
    static func execute(_ argv: [String]) async throws -> String {
        var command = try parse(argv)
        let result = try await command.execute()
        return try command.output.render(result)
    }

    /// Run `operation`, giving up after `seconds`. The abandoned work keeps
    /// running until its own cap reaps it; only the wait stops.
    static func withDeadline(
        seconds: Double,
        _ operation: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let slot = ConcurrentSlot<Bool>()
            let lock = NSLock()
            @Sendable func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if slot.get() != nil { return false }
                slot.set(true)
                return true
            }
            Task.detached {
                do {
                    let value = try await operation()
                    if claim() { continuation.resume(returning: value) }
                } catch {
                    if claim() { continuation.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if claim() {
                    continuation.resume(throwing: MCPServerRuntimeError.inProcessTimedOut(seconds: Int(seconds)))
                }
            }
        }
    }

    /// Tools that hit the deadline this session; they run in a child from then on.
    private static let demotedLock = NSLock()
    private nonisolated(unsafe) static var demoted: Set<String> = []

    static func isDemoted(_ tool: String) -> Bool {
        demotedLock.lock()
        defer { demotedLock.unlock() }
        return demoted.contains(tool)
    }

    static func demote(_ tool: String) {
        demotedLock.lock()
        defer { demotedLock.unlock() }
        demoted.insert(tool)
    }

    /// String form of `printAgentError`, with the same code/message/remediation
    /// derivation the child's error path uses.
    static func errorEnvelope(_ error: Error, startedAt: Date) -> String {
        let envelope = AgentErrorEnvelope(
            v: AGENT_SCHEMA_VERSION,
            status: "error",
            durationMs: max(0, Int(Date().timeIntervalSince(startedAt) * 1000)),
            error: AgentError.from(error).error
        )
        guard let bytes = try? JSONEncoder().encode(envelope) else {
            // A fixed struct of strings and ints; keep the result non-empty if encoding ever fails.
            return #"{"v":\#(AGENT_SCHEMA_VERSION),"status":"error","duration_ms":0,"error":{"code":"unknown_error","message":"failed to encode error envelope","next_step":{"retryable":false}}}"#
        }
        // A safety refusal carries structured fields (the confirm token and
        // preview) beside its message.
        if let details = (error as? SafetyError)?.details,
           case var .object(root)? = try? JSONDecoder().decode(JSONValue.self, from: bytes),
           case var .object(payload)? = root["error"] {
            payload["details"] = .object(details)
            root["error"] = .object(payload)
            return ArgRedactor.canonicalJSON(.object(root))
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
