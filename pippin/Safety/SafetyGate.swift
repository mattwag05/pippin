import Foundation

/// A small JSON state file: read whole, replaced in one rename, mode 0600.
/// shortcut: no cross-process lock, so two MCP servers acting in the same instant can lose one update; add an flock if that matters.
private func loadState<T: Decodable>(_ type: T.Type, _ path: String) -> T? {
    FileManager.default.contents(atPath: path).flatMap { try? JSONDecoder().decode(type, from: $0) }
}

private func saveState(_ value: some Encodable, _ path: String) throws {
    try PrivateFile.writeAtomically(JSONEncoder().encode(value), to: path)
}

/// Sliding-window call counts per tool, kept on disk so a server restart does
/// not reset them.
struct RateLimiter {
    let path: String

    /// Seconds until a call is allowed again, or nil when one is allowed now.
    func retryAfter(tool: String, limit: SafetyPolicy.Limit, now: Date) -> Int? {
        let cutoff = now.timeIntervalSince1970 - Double(limit.perSeconds)
        let recent = (loadState([String: [Double]].self, path)?[tool] ?? []).filter { $0 > cutoff }.sorted()
        guard recent.count >= limit.max else { return nil }
        // The call that must age out before the count drops below the limit.
        let blocking = limit.max > 0 ? recent[recent.count - limit.max] : now.timeIntervalSince1970
        return max(1, Int((blocking + Double(limit.perSeconds) - now.timeIntervalSince1970).rounded(.up)))
    }

    func record(tool: String, limit: SafetyPolicy.Limit, now: Date) throws {
        var state = loadState([String: [Double]].self, path) ?? [:]
        let cutoff = now.timeIntervalSince1970 - Double(limit.perSeconds)
        state[tool] = (state[tool] ?? []).filter { $0 > cutoff } + [now.timeIntervalSince1970]
        try saveState(state, path)
    }
}

/// What an `idempotencyKey` did the first time, kept for 24 hours.
struct IdempotencyStore {
    static let lifetime: TimeInterval = 24 * 3600

    struct Record: Codable, Equatable {
        let tool: String
        let hash: String
        let at: Double
        /// Nil until the action finishes: a record with no result means the
        /// outcome is unknown (timed out, or the server died mid-action).
        var result: String?
    }

    let path: String

    private func load(now: Date) -> [String: Record] {
        (loadState([String: Record].self, path) ?? [:]).filter { now.timeIntervalSince1970 - $0.value.at < Self.lifetime }
    }

    func record(for key: String, now: Date) -> Record? {
        load(now: now)[key]
    }

    /// `nil` removes the key, so a clean failure can be tried again.
    func set(_ record: Record?, for key: String, now: Date) throws {
        var state = load(now: now)
        state[key] = record
        try saveState(state, path)
    }
}

/// The one place every mutating MCP tool call passes through: policy, confirm
/// tokens, rate limits, the action log, undo records and idempotency keys.
/// `MCPDispatcher` calls `run` for any tool whose effect is not `.readOnly`.
final class SafetyGate: @unchecked Sendable {
    static let shared = SafetyGate()
    static let tokenLifetime: TimeInterval = 300
    static let reservedArguments = ["confirmToken", "idempotencyKey"]

    let policyPath: String
    let stateDir: String
    private let now: @Sendable () -> Date

    // Confirm tokens live only here, so a server restart forgets them all.
    private let lock = NSLock()
    private var tokens: [String: (hash: String, expires: Date)] = [:]
    private var usedTokens: Set<String> = []

    init(
        policyPath: String = SafetyPaths.policyPath(), stateDir: String = SafetyPaths.stateDir(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policyPath = policyPath
        self.stateDir = stateDir
        self.now = now
    }

    var log: ActionLog { ActionLog(path: stateDir + "/actions.jsonl") }
    private var limiter: RateLimiter { RateLimiter(path: stateDir + "/rate-limits.json") }
    private var idempotency: IdempotencyStore { IdempotencyStore(path: stateDir + "/idempotency.json") }

    private func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Schema

    /// The reserved arguments every mutating tool accepts, added to its schema
    /// here so no tool has to declare them.
    static func withReservedArguments(_ schema: JSONValue) -> JSONValue {
        guard case var .object(root) = schema, case var .object(properties)? = root["properties"] else { return schema }
        properties["confirmToken"] = Schema.string("The confirmToken from a confirmation_required error, sent with the same arguments.")
        // A tool with no dry run of its own still gets one, answered by the gate.
        if properties["dryRun"] == nil {
            properties["dryRun"] = Schema.boolean("Report what the call would do without doing it.", default: false)
        }
        properties["idempotencyKey"] = Schema.string("A repeat of this key and arguments within 24 hours replays the first result.")
        root["properties"] = .object(properties)
        return .object(root)
    }

    // MARK: - Tokens

    private func issueToken(hash: String) -> (token: String, expires: Date) {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let expires = now().addingTimeInterval(Self.tokenLifetime)
        lock.lock()
        defer { lock.unlock() }
        tokens = tokens.filter { $0.value.expires > now() }
        tokens[token] = (hash, expires)
        return (token, expires)
    }

    /// Single use: a token is spent by the first call that presents it with
    /// the right arguments in time.
    private func redeemToken(_ token: String, hash: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let issued = tokens[token] else {
            throw usedTokens.contains(token) ? SafetyError.confirmTokenReused : SafetyError.confirmTokenInvalid
        }
        guard issued.expires > now() else {
            tokens[token] = nil
            throw SafetyError.confirmTokenExpired
        }
        guard issued.hash == hash else { throw SafetyError.confirmTokenMismatch }
        tokens[token] = nil
        usedTokens.insert(token)
    }

    // MARK: - Reads

    /// A read is only ever stopped by an explicit `deny`. A policy file that
    /// does not parse stops writes, not reads.
    func checkRead(_ tool: MCPTool, tools: [MCPTool]) throws {
        guard let policy = try? SafetyPolicy.load(path: policyPath, tools: tools) else { return }
        let (rule, source) = policy.rule(for: tool)
        if rule == .deny { throw SafetyError.policyDenied(tool: tool.name, source: source) }
    }

    // MARK: - Writes

    private static func options(_ argv: [String]) -> ArraySlice<String> {
        argv.prefix { $0 != "--" }
    }

    /// A call that only previews. `mail apply-rules` previews unless `--live`.
    private static func isDryRun(_ argv: [String]) -> Bool {
        options(argv).contains("--dry-run") || (argv.starts(with: ["mail", "apply-rules"]) && !options(argv).contains("--live"))
    }

    /// The log outcome of a finished child, from its envelope.
    private static func outcome(of result: (text: String, isError: Bool), dryRun: Bool) -> (outcome: String, code: String?) {
        guard result.isError else { return (dryRun ? "dry_run" : "success", nil) }
        let code = (try? JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8)))?["error"]?["code"]?.stringValue
        return (code?.hasSuffix("outcome_unknown") == true ? "outcome_unknown" : "failed", code)
    }

    private static func outcome(of error: Error) -> String {
        switch error {
        case SafetyError.policyDenied: return "denied"
        case SafetyError.confirmationRequired: return "confirmation_required"
        case SafetyError.rateLimited: return "rate_limited"
        default: return "refused"
        }
    }

    /// A summary a person can check a call against: the tool and its
    /// arguments, with bodies shown only as lengths.
    static func summary(tool: String, redactedArgs: JSONValue) -> String {
        guard case let .object(dict) = redactedArgs, !dict.isEmpty else { return "\(tool) with no arguments" }
        let parts = dict.keys.sorted().map { key -> String in
            if let length = dict[key]?["length"]?.intValue { return "\(key)=(\(length) characters, not shown)" }
            return "\(key)=\(ArgRedactor.canonicalJSON(dict[key] ?? .null))"
        }
        return "\(tool) with " + parts.joined(separator: ", ")
    }

    /// Run a mutating tool call through every control, then through `runArgv`.
    /// Returns the tool's result, or throws the refusal. `runArgv` throws only
    /// when the child could not be run to an answer.
    func run(
        tool: MCPTool, arguments: JSONValue?, tools: [MCPTool], runArgv: ArgvRunner
    ) async throws -> (text: String, isError: Bool) {
        // Reserved arguments come off before the tool's own schema sees them.
        var dict: [String: JSONValue] = [:]
        if case let .object(given)? = arguments { dict = given }
        var reserved: [String: String] = [:]
        for name in Self.reservedArguments {
            guard let value = dict.removeValue(forKey: name) else { continue }
            guard let text = value.stringValue, (1 ... 128).contains(text.count), !text.contains("\0") else {
                throw SafetyError.invalidReservedArgument(name)
            }
            reserved[name] = text
        }
        // `dryRun` on a tool that has no dry run of its own is answered here.
        var gateDryRun = false
        if tool.inputSchema["properties"]?["dryRun"] == nil, let value = dict.removeValue(forKey: "dryRun") {
            guard let flag = value.boolValue else { throw SafetyError.invalidReservedArgument("dryRun") }
            gateDryRun = flag
        }
        let isObject: Bool = { if case .object? = arguments { return true } else { return arguments == nil } }()
        var args: JSONValue? = isObject ? .object(dict) : arguments

        let loaded = Result { try SafetyPolicy.load(path: policyPath, tools: tools) }
        let rule = (try? loaded.get())?.rule(for: tool)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16).description
        let redacted = ArgRedactor.redact(args, schema: tool.inputSchema)
        var line = ActionLogLine(
            ts: timestamp(now()), id: id, phase: "intent", tool: tool.name, args: redacted,
            rule: rule?.rule.rawValue ?? "invalid_policy", idempotencyKey: reserved["idempotencyKey"]
        )
        // No intent line, no action: a write nobody can audit does not happen.
        do {
            try log.append(line)
        } catch {
            throw SafetyError.auditLogUnavailable(path: log.path, detail: error.localizedDescription)
        }
        line.phase = "outcome"
        line.args = nil
        func finish(_ outcome: String, code: String? = nil, undo: UndoInfo) {
            line.ts = timestamp(now())
            line.outcome = outcome
            line.errorCode = code
            line.undo = undo
            try? log.append(line)
        }

        // `ran`: the tool's child was started. `acting`: and not as a dry run.
        var ran = false
        var acting = false
        do {
            let policy = try loaded.get()
            guard let rule, rule.rule != .deny else {
                throw SafetyError.policyDenied(tool: tool.name, source: rule?.source ?? "default")
            }
            // Under `confirm` the token is the confirmation, so the tool's own
            // `confirm` flag is set for the caller; without a token nothing below acts.
            let hasConfirmFlag = tool.inputSchema["properties"]?["confirm"] != nil
            let hasDryRunFlag = tool.inputSchema["properties"]?["dryRun"] != nil
            // An explicit `confirm: false` or `dryRun: true` still asks for a preview only.
            let previewOnly = dict["dryRun"]?.boolValue == true || dict["confirm"]?.boolValue == false
            if rule.rule == .confirm || gateDryRun, hasConfirmFlag, isObject, !previewOnly {
                dict["confirm"] = .bool(true)
                args = .object(dict)
            }
            try SchemaValidator.validate(args: args, against: tool.inputSchema)
            let argv = try tool.buildArgs(args)
            let dryRun = Self.isDryRun(argv)

            // What a token and an idempotency key are bound to.
            var hashed = dict
            hashed["confirm"] = nil
            let hash = ArgRedactor.sha256(tool.name + "\n" + ArgRedactor.canonicalJSON(.object(hashed)))

            /// The tool's own preview of this call, where it has one.
            func nativePreview() -> [String]? {
                var previewArgs = dict
                previewArgs["confirm"] = nil
                if hasDryRunFlag { previewArgs["dryRun"] = .bool(true) }
                guard let previewArgv = try? tool.buildArgs(.object(previewArgs)), Self.isDryRun(previewArgv) else { return nil }
                return previewArgv
            }
            if gateDryRun, !dryRun {
                if let previewArgv = nativePreview() {
                    ran = true
                    let result = try await runArgv(previewArgv)
                    finish(Self.outcome(of: result, dryRun: true).outcome, undo: .no("a dry run changes nothing"))
                    return result
                }
                // No preview in the command: the arguments were checked and the
                // argv built, and this says what would run.
                finish("dry_run", undo: .no("a dry run changes nothing"))
                return (ArgRedactor.canonicalJSON(.object([
                    "v": .int(Int64(AGENT_SCHEMA_VERSION)), "status": .string("ok"), "duration_ms": .int(0),
                    "data": .object([
                        "dry_run": .bool(true), "tool": .string(tool.name), "rule": .string(rule.rule.rawValue),
                        "would_do": .string(Self.summary(tool: tool.name, redactedArgs: redacted)), "arguments": redacted,
                    ]),
                ])), false)
            }

            if dryRun {
                ran = true
                let result = try await runArgv(argv)
                finish(Self.outcome(of: result, dryRun: true).outcome, undo: .no("a dry run changes nothing"))
                return result
            }

            if let key = reserved["idempotencyKey"], let earlier = idempotency.record(for: key, now: now()) {
                guard earlier.tool == tool.name, earlier.hash == hash else { throw SafetyError.idempotencyKeyConflict(key) }
                guard let text = earlier.result,
                      case var .object(envelope)? = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
                else { throw SafetyError.priorOutcomeUnknown(tool: tool.name, key: key) }
                envelope["replayed"] = .bool(true)
                finish("replayed", undo: .no("a replay changes nothing"))
                return (ArgRedactor.canonicalJSON(.object(envelope)), false)
            }

            let limit = policy.limit(for: tool)
            if let limit, let wait = limiter.retryAfter(tool: tool.name, limit: limit, now: now()) {
                throw SafetyError.rateLimited(tool: tool.name, limit: limit, retryAfter: wait)
            }

            if rule.rule == .confirm {
                guard let token = reserved["confirmToken"] else {
                    // Show what would happen through the tool's own preview, where it has one.
                    var preview: JSONValue?
                    if let previewArgv = nativePreview() {
                        preview = await Undo.data(of: try? runArgv(previewArgv))
                    }
                    let issued = issueToken(hash: hash)
                    throw SafetyError.confirmationRequired(
                        tool: tool.name, token: issued.token,
                        summary: Self.summary(tool: tool.name, redactedArgs: redacted),
                        expiresAt: timestamp(issued.expires), preview: preview
                    )
                }
                try redeemToken(token, hash: hash)
            }

            // From here the call counts and acts.
            if let limit { try limiter.record(tool: tool.name, limit: limit, now: now()) }
            if let key = reserved["idempotencyKey"] {
                try idempotency.set(.init(tool: tool.name, hash: hash, at: now().timeIntervalSince1970, result: nil), for: key, now: now())
            }
            let before = await Undo.snapshot(tool: tool.name, args: .object(dict), run: runArgv)
            ran = true
            acting = true
            let result = try await runArgv(argv)
            let (outcome, code) = Self.outcome(of: result, dryRun: false)
            var undo = UndoInfo.no(outcome == "failed" ? "the action failed" : "the outcome is unknown")
            if outcome == "success" {
                undo = await Undo.record(
                    tool: tool.name, args: .object(dict), before: before, result: Undo.data(of: result),
                    id: id, stateDir: stateDir, run: runArgv
                )
            }
            if let key = reserved["idempotencyKey"], outcome != "outcome_unknown" {
                // A clean failure frees the key; a success keeps its result for replays.
                let record = IdempotencyStore.Record(tool: tool.name, hash: hash, at: now().timeIntervalSince1970, result: result.text)
                try? idempotency.set(outcome == "success" ? record : nil, for: key, now: now())
            }
            finish(outcome, code: code, undo: undo)
            return result
        } catch {
            // A child that timed out, crashed or never answered may have acted.
            let mapped = ran ? MCPServerRuntime.outcomeUnknownIfMutating(error, tool: tool, tools: tools) : error
            let unknown: Bool = {
                switch mapped {
                case MCPServerRuntimeError.outcomeUnknown, MCPServerRuntimeError.childCrashed: return acting
                default: return false
                }
            }()
            if acting, !unknown, let key = reserved["idempotencyKey"] { try? idempotency.set(nil, for: key, now: now()) }
            finish(
                unknown ? "outcome_unknown" : (ran ? "failed" : Self.outcome(of: error)), code: agentErrorCode(for: mapped),
                undo: .no(unknown ? "the outcome is unknown" : "nothing was done")
            )
            throw mapped
        }
    }
}
