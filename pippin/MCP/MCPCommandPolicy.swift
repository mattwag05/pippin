import Foundation

/// What `batch` and `job_run` may run for an MCP client. Both take raw pippin
/// argv, which would otherwise reach every command the curated tool surface
/// leaves out (`do`, `shell`, `mail index`, `init`) and skip gates that live in
/// a tool's `buildArgs`. The plain CLI `pippin batch` / `pippin job run` do not
/// go through this.
enum MCPCommandPolicy {
    enum Violation: LocalizedError, RemediableError, Equatable {
        case notExposed(String)
        case nested(String)
        case autonomousSend
        case sendWithoutDraft
        case directCallRequired(command: String, tool: String)

        var errorDescription: String? {
            switch self {
            case let .notExposed(command):
                return "`pippin \(command)` has no MCP tool, so it cannot run through batch or job_run."
            case let .nested(command):
                return "`pippin \(command)` cannot be nested inside batch or job_run."
            case .autonomousSend:
                return "--autonomous is not available to MCP clients."
            case .sendWithoutDraft:
                return "`messages send` needs --draft here: MCP clients can only log a draft."
            case let .directCallRequired(command, tool):
                return "`pippin \(command)` is gated by the safety policy (confirm, deny or a rate limit), so call the \(tool) tool directly instead of through batch or job_run."
            }
        }

        var agentCode: String {
            switch self {
            case .notExposed: return "command_not_allowed"
            case .nested: return "nested_dispatch_not_allowed"
            case .autonomousSend: return "autonomous_not_allowed"
            case .sendWithoutDraft: return "draft_required"
            case .directCallRequired: return "direct_call_required"
            }
        }

        var nextStep: NextStep { .none }
    }

    /// Tool names whose CLI path is not `<group> <rest-with-dashes>`.
    private static let pathOverrides: [String: [String]] = [
        "memos_capture_to_reminders": ["memos", "capture"],
        "messages_exclude_list": ["messages", "exclude", "list"],
        "messages_exclude_add": ["messages", "exclude", "add"],
        "messages_exclude_remove": ["messages", "exclude", "remove"],
        "action_log": ["log"],
    ]

    /// The leading argv tokens of the command a tool runs: `mail_apply_rules`
    /// is `mail apply-rules`, `status` is `status`.
    /// `ToolRegistryTests` checks this against every tool's built argv.
    static func commandPath(for toolName: String) -> [String] {
        if let path = pathOverrides[toolName] { return path }
        let parts = toolName.split(separator: "_", maxSplits: 1).map(String.init)
        return [parts[0]] + parts.dropFirst().map { $0.replacingOccurrences(of: "_", with: "-") }
    }

    /// The tool whose command `argv` runs, or a `Violation`.
    @discardableResult
    static func check(_ argv: [String], tools: [MCPTool] = MCPToolRegistry.tools) throws -> MCPTool {
        let matches = tools.filter { argv.starts(with: commandPath(for: $0.name)) }
        guard let tool = matches.max(by: { commandPath(for: $0.name).count < commandPath(for: $1.name).count }) else {
            throw Violation.notExposed(argv.prefix(2).joined(separator: " "))
        }
        if tool.name == "batch" || tool.name == "job_run" || tool.name == "undo" {
            throw Violation.nested(commandPath(for: tool.name).joined(separator: " "))
        }
        // Tokens after a bare `--` are positionals, not flags.
        let options = argv.prefix { $0 != "--" }
        if options.contains(where: { $0.hasPrefix("--autonomous") }) {
            throw Violation.autonomousSend
        }
        if tool.name == "messages_send", !options.contains("--draft") {
            throw Violation.sendWithoutDraft
        }
        // batch and job_run run a command without the dispatcher's gate, so a
        // command the policy confirms, denies or rate limits cannot go through
        // them: it would skip the token, the count and the log. A file that
        // does not parse throws here, which refuses the entry.
        let policy = try SafetyPolicy.load(tools: tools)
        let rule = policy.rule(for: tool).rule
        if rule == .deny || (tool.effect != .readOnly && !options.contains("--dry-run")
            && (rule != .allow || policy.limit(for: tool) != nil)) {
            throw Violation.directCallRequired(command: commandPath(for: tool.name).joined(separator: " "), tool: tool.name)
        }
        return tool
    }
}
