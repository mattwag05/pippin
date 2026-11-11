import ArgumentParser
import Foundation

// MARK: - policy show

/// The policy as the MCP server applies it, one row per tool.
struct PolicyReport: Codable {
    struct Row: Codable {
        let tool: String
        let effect: String
        let rule: String
        /// The key in the file that decided the rule, `default`, or `invalid_policy`.
        let source: String
        let limit: SafetyPolicy.Limit?
    }

    let path: String
    /// `built-in` (no file), `file`, or `invalid` (the file does not parse).
    let source: String
    let error: String?
    let tools: [Row]

    static func make(path: String = SafetyPaths.policyPath(), tools: [MCPTool] = MCPToolRegistry.tools) -> PolicyReport {
        let exists = FileManager.default.fileExists(atPath: path)
        do {
            let policy = try SafetyPolicy.load(path: path, tools: tools)
            return PolicyReport(path: path, source: exists ? "file" : "built-in", error: nil, tools: tools.map { tool in
                let (rule, source) = policy.rule(for: tool)
                return Row(
                    tool: tool.name, effect: tool.effect == .readOnly ? "read" : "write",
                    rule: rule.rawValue, source: source, limit: policy.limit(for: tool)
                )
            })
        } catch {
            // Fail closed: with a file that does not parse, every write is refused.
            return PolicyReport(
                path: path, source: "invalid", error: error.localizedDescription,
                tools: tools.map { tool in
                    let read = tool.effect == .readOnly
                    return Row(
                        tool: tool.name, effect: read ? "read" : "write", rule: read ? "allow" : "deny",
                        source: read ? "default" : "invalid_policy", limit: nil
                    )
                }
            )
        }
    }
}

public struct PolicyCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Show the safety policy the MCP server applies to each tool.",
        subcommands: [Show.self]
    )

    public init() {}

    public struct Show: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show the effective rule (allow, deny, confirm) and rate limit for every MCP tool. Read-only."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let report = PolicyReport.make()
            return AgentResult(report, warnings: report.error.map { [$0] })
        }
    }
}

// MARK: - log

public struct LogCommand: AgentCommand {
    public static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "List actions the MCP server ran or refused, newest first."
    )

    @Option(name: .long, help: "Maximum actions to return (default: 50).")
    public var limit: Int = 50

    @Option(name: .long, help: "Only actions at or after this time: YYYY-MM-DD or ISO 8601.")
    public var since: String?

    @Option(name: .long, help: "Only actions of this MCP tool, e.g. mail_send.")
    public var tool: String?

    @OptionGroup public var pagination: PaginationOptions

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func validate() throws {
        if let since, parseCalendarDate(since) == nil {
            throw ValidationError("--since must be in YYYY-MM-DD or ISO 8601 format.")
        }
        guard limit > 0 else { throw ValidationError("--limit must be positive.") }
    }

    public mutating func execute() async throws -> AgentResult {
        let entries = ActionLog(path: ActionLog.defaultPath()).entries()
        let rows = Self.filter(entries, since: since.flatMap { parseCalendarDate($0) }, tool: tool)
        let hash = Pagination.filterHash(["since": since, "tool": tool])
        let (offset, pageSize) = try Pagination.resolve(pagination, defaultPageSize: limit, filterHash: hash)
        return try .page(Self.keysetPage(
            rows, of: entries, pagination: pagination, offset: offset, pageSize: pageSize, filterHash: hash
        ))
    }

    /// New actions land at the top of a newest-first list, so an offset cursor
    /// repeats rows. The key is the entry's position in the whole log (oldest = 0).
    static func keysetPage(
        _ rows: [ActionEntry], of entries: [ActionEntry], pagination: PaginationOptions,
        offset: Int, pageSize: Int, filterHash: String
    ) throws -> Page<ActionEntry> {
        let seq = Dictionary(entries.enumerated().map { ($1.id, Int64(entries.count - 1 - $0)) }) { _, last in last }
        return try Pagination.paginateKeyset(
            all: rows, offset: offset, pageSize: pageSize, filterHash: filterHash,
            anchor: Pagination.anchor(of: pagination), key: { seq[$0.id] ?? 0 }, id: \.id, descending: true
        )
    }

    static func filter(_ entries: [ActionEntry], since: Date?, tool: String?) -> [ActionEntry] {
        let formatter = ISO8601DateFormatter()
        return entries.filter { entry in
            if let tool, entry.tool != tool { return false }
            if let since, let at = formatter.date(from: entry.ts), at < since { return false }
            return true
        }
    }
}

// MARK: - undo

public struct UndoCommand: AgentCommand {
    public static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Reverse a logged action by its id (from `pippin log`), where it can be reversed."
    )

    @Argument(help: "Action id from `pippin log`.")
    public var id: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public mutating func execute() async throws -> AgentResult {
        let pippinPath = MCPServerRuntime.resolvePippinPath()
        let ownGroup = isMCPContext()
        // The check and the inverse each get a child; together they must fit the 60s MCP cap.
        let outcome = try await Undo.perform(id: id) { argv in
            try await detachBlocking {
                let child = try MCPServerRuntime.runChild(
                    argv: argv, pippinPath: pippinPath, timeoutSeconds: 25, ownProcessGroup: ownGroup
                )
                let text = String(decoding: child.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw MCPServerRuntimeError.childNoOutput(exitCode: child.exitCode) }
                return (text, child.exitCode != 0)
            }
        }
        return AgentResult(outcome)
    }
}
