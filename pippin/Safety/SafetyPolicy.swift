import Foundation

/// Where the safety model keeps its files. Both locations take an environment
/// override so tests and e2e checks never touch the user's own.
enum SafetyPaths {
    // Under XCTest the defaults move to a per-process temp directory: a test
    // that reaches the dispatcher without injecting a gate must not write the
    // developer's real action log or read their real policy.
    private static let testRoot: String? = NSClassFromString("XCTestCase") == nil
        ? nil : NSTemporaryDirectory() + "pippin-safety-tests-\(ProcessInfo.processInfo.processIdentifier)"

    static func policyPath() -> String {
        if let override = ProcessInfo.processInfo.environment["PIPPIN_POLICY"], !override.isEmpty { return override }
        if let testRoot { return testRoot + "/policy.json" }
        return NSHomeDirectory() + "/.config/pippin/policy.json"
    }

    /// Action log, rate-limit and idempotency state, undo sidecars.
    static func stateDir() -> String {
        if let override = ProcessInfo.processInfo.environment["PIPPIN_STATE_DIR"], !override.isEmpty { return override }
        if let testRoot { return testRoot + "/state" }
        return NSHomeDirectory() + "/.local/share/pippin"
    }
}

/// The rules in `policy.json`: what an MCP client may do with each tool.
struct SafetyPolicy: Equatable {
    enum Rule: String, Codable {
        case allow, deny, confirm
    }

    struct Limit: Codable, Equatable {
        let max: Int
        let perSeconds: Int

        private enum CodingKeys: String, CodingKey {
            case max
            case perSeconds = "per_seconds"
        }
    }

    /// Keys are a tool name, `<prefix>*` or `*`.
    var rules: [String: Rule] = [:]
    var limits: [String: Limit] = [:]

    static let sendTools: Set = ["mail_send", "mail_reply", "mail_forward", "messages_send"]

    private static func isDelete(_ toolName: String) -> Bool {
        toolName.hasSuffix("_delete")
    }

    /// The built-in policy, used for any tool no rule in the file matches.
    static func defaultRule(for tool: MCPTool) -> Rule {
        guard tool.effect != .readOnly else { return .allow }
        return sendTools.contains(tool.name) || isDelete(tool.name) ? .confirm : .allow
    }

    static func defaultLimit(for toolName: String) -> Limit? {
        if sendTools.contains(toolName) { return Limit(max: 10, perSeconds: 3600) }
        if isDelete(toolName) { return Limit(max: 30, perSeconds: 3600) }
        return nil
    }

    /// The most specific key that matches: exact name, then the longest
    /// `prefix*`, then `*`.
    private static func bestMatch<Value>(_ table: [String: Value], _ toolName: String) -> (key: String, value: Value)? {
        if let exact = table[toolName] { return (toolName, exact) }
        return table
            .filter { $0.key.hasSuffix("*") && toolName.hasPrefix($0.key.dropLast()) }
            .max { $0.key.count < $1.key.count }
            .map { ($0.key, $0.value) }
    }

    /// `source` is the matching key in the file, or `default`.
    func rule(for tool: MCPTool) -> (rule: Rule, source: String) {
        guard let match = Self.bestMatch(rules, tool.name) else { return (Self.defaultRule(for: tool), "default") }
        // A read has nothing to confirm; only `deny` restricts it.
        if tool.effect == .readOnly, match.value == .confirm { return (.allow, match.key) }
        return (match.value, match.key)
    }

    /// Reads are never rate limited.
    func limit(for tool: MCPTool) -> Limit? {
        guard tool.effect != .readOnly else { return nil }
        return Self.bestMatch(limits, tool.name)?.value ?? Self.defaultLimit(for: tool.name)
    }

    /// The built-in policy when the file is absent; `SafetyError.invalidPolicy`
    /// when it exists but cannot be used. A rule that names no known tool is
    /// an error too: a typo must not read as "no rule".
    static func load(path: String = SafetyPaths.policyPath(), tools: [MCPTool] = MCPToolRegistry.tools) throws -> SafetyPolicy {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch CocoaError.fileReadNoSuchFile {
            return SafetyPolicy()
        } catch {
            throw SafetyError.invalidPolicy(path: path, detail: error.localizedDescription)
        }
        struct File: Decodable {
            let rules: [String: Rule]?
            let limits: [String: Limit]?
        }
        do {
            let root = try JSONDecoder().decode([String: JSONValue].self, from: data)
            if let unknown = root.keys.sorted().first(where: { $0 != "rules" && $0 != "limits" }) {
                throw SafetyError.invalidPolicy(path: path, detail: "unknown key \"\(unknown)\" (expected rules, limits)")
            }
            let file = try JSONDecoder().decode(File.self, from: data)
            let policy = SafetyPolicy(rules: file.rules ?? [:], limits: file.limits ?? [:])
            let names = Set(tools.map(\.name))
            for key in Array(policy.rules.keys) + Array(policy.limits.keys) {
                let prefix = key.hasSuffix("*") ? String(key.dropLast()) : nil
                let known = prefix.map { prefix in !prefix.contains("*") && names.contains { $0.hasPrefix(prefix) } }
                    ?? names.contains(key)
                guard known else {
                    throw SafetyError.invalidPolicy(path: path, detail: "\"\(key)\" matches no tool")
                }
            }
            if let bad = policy.limits.first(where: { $0.value.max < 0 || $0.value.perSeconds <= 0 }) {
                throw SafetyError.invalidPolicy(path: path, detail: "limit for \"\(bad.key)\" needs max >= 0 and per_seconds > 0")
            }
            return policy
        } catch let error as SafetyError {
            throw error
        } catch {
            throw SafetyError.invalidPolicy(path: path, detail: error.localizedDescription)
        }
    }
}

/// Refusals from the safety model. All are decided before the action runs.
enum SafetyError: LocalizedError, RemediableError {
    case invalidPolicy(path: String, detail: String)
    case policyDenied(tool: String, source: String)
    case confirmationRequired(tool: String, token: String, summary: String, expiresAt: String, preview: JSONValue?)
    case confirmTokenInvalid
    case confirmTokenReused
    case confirmTokenExpired
    case confirmTokenMismatch
    case rateLimited(tool: String, limit: SafetyPolicy.Limit, retryAfter: Int)
    case auditLogUnavailable(path: String, detail: String)
    case idempotencyKeyConflict(String)
    case priorOutcomeUnknown(tool: String, key: String)
    case invalidReservedArgument(String)
    case actionNotFound(String)
    case undoNotSupported(id: String, reason: String)
    case alreadyUndone(String)
    case undoTargetChanged(String)
    case undoFailed(id: String, code: String, message: String)

    var agentCode: String {
        switch self {
        case .invalidPolicy: return "invalid_policy"
        case .policyDenied: return "policy_denied"
        case .confirmationRequired: return "confirmation_required"
        case .confirmTokenInvalid: return "confirm_token_invalid"
        case .confirmTokenReused: return "confirm_token_reused"
        case .confirmTokenExpired: return "confirm_token_expired"
        case .confirmTokenMismatch: return "confirm_token_mismatch"
        case .rateLimited: return "rate_limited"
        case .auditLogUnavailable: return "audit_log_unavailable"
        case .idempotencyKeyConflict: return "idempotency_key_conflict"
        case .priorOutcomeUnknown: return "outcome_unknown"
        case .invalidReservedArgument: return "invalid_argument"
        case .actionNotFound: return "action_not_found"
        case .undoNotSupported: return "undo_not_supported"
        case .alreadyUndone: return "already_undone"
        case .undoTargetChanged: return "undo_target_changed"
        case .undoFailed: return "undo_failed"
        }
    }

    var nextStep: NextStep {
        switch self {
        case let .invalidPolicy(path, _):
            return .human("Fix the JSON in \(path), or move that file aside to run on the built-in policy.")
        case .confirmationRequired:
            // Not a `next_call`: the repeat needs the caller's own arguments, and
            // this is the point where a host application can put a person.
            return .human("Check the summary against what was asked for (ask the user if it is theirs to approve), then repeat the call with the same arguments plus details.confirmToken.")
        case let .rateLimited(_, _, retryAfter):
            return .retry(after: retryAfter)
        case let .auditLogUnavailable(path, _):
            return .human("Make \(path) writable by this user.")
        default:
            return .none
        }
    }

    /// Structured fields beside `message`, merged into the error envelope.
    var details: [String: JSONValue]? {
        guard case let .confirmationRequired(_, token, summary, expiresAt, preview) = self else { return nil }
        var details: [String: JSONValue] = [
            "confirmToken": .string(token), "summary": .string(summary), "expires_at": .string(expiresAt),
        ]
        if let preview { details["preview"] = preview }
        return details
    }

    var errorDescription: String? {
        switch self {
        case let .invalidPolicy(path, detail):
            return "pippin's policy file at \(path) could not be used: \(detail). Every tool that changes something is refused until it parses."
        case let .policyDenied(tool, source):
            return "\(tool) is denied by policy (rule \"\(source)\"). Nothing was done."
        case let .confirmationRequired(_, _, summary, expiresAt, _):
            return "Nothing was done yet. To go ahead, repeat this call with the same arguments plus confirmToken (in details) before \(expiresAt). It will: \(summary)"
        case .confirmTokenInvalid:
            return "confirmToken is not one this server issued (tokens do not survive a server restart). Call again without it to get a new one."
        case .confirmTokenReused:
            return "confirmToken was already used. Call again without it to get a new one."
        case .confirmTokenExpired:
            return "confirmToken has expired. Call again without it to get a new one."
        case .confirmTokenMismatch:
            return "confirmToken was issued for a different tool or different arguments. Nothing was done."
        case let .rateLimited(tool, limit, retryAfter):
            return "\(tool) is limited to \(limit.max) calls per \(limit.perSeconds)s. Retry in \(retryAfter)s."
        case let .auditLogUnavailable(path, detail):
            return "The action log at \(path) could not be written (\(detail)), so nothing was done."
        case let .idempotencyKeyConflict(key):
            return "idempotencyKey \"\(key)\" was already used with different arguments. Nothing was done."
        case let .priorOutcomeUnknown(tool, key):
            return "An earlier \(tool) call with idempotencyKey \"\(key)\" ended with an unknown outcome: it may or may not have taken effect. It was not run again; check the current state."
        case let .invalidReservedArgument(name):
            return "Argument '\(name)' must be a string of 1 to 128 characters."
        case let .actionNotFound(id):
            return "No logged action has id \(id)."
        case let .undoNotSupported(id, reason):
            return "Action \(id) cannot be undone: \(reason)"
        case let .alreadyUndone(id):
            return "Action \(id) was already undone."
        case let .undoTargetChanged(id):
            return "The target of action \(id) no longer looks the way that action left it, so it was not changed."
        case let .undoFailed(id, code, message):
            return "Undoing action \(id) failed (\(code)): \(message)"
        }
    }
}
