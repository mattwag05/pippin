import ArgumentParser
import Foundation

public struct MessagesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Read Apple Messages conversations and send (draft by default).",
        subcommands: [List.self, Search.self, Show.self, Send.self, Exclude.self]
    )

    public init() {}

    /// Build the Contacts reverse index for sender/participant name resolution,
    /// unless disabled. Best-effort: an empty index when Contacts isn't authorized
    /// (resolution silently no-ops). See ContactsBridge.contactIndex.
    static func contactIndex(disabled: Bool) -> ContactIndex {
        disabled ? ContactIndex() : ContactsBridge.contactIndex()
    }

    /// Build the contact index honoring the command's `--no-contacts` /
    /// `--contacts` flags and the `resolveContacts` default in the caller's
    /// already-loaded `config`.
    static func contactIndex(_ options: ContactResolutionOptions, config: PippinConfig?) -> ContactIndex {
        contactIndex(disabled: !options.shouldResolve(config: config))
    }

    // MARK: - List

    public struct List: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List recent conversations (most recent first)."
        )

        @Option(name: .long, help: "Only conversations with a message in the last N hours (defaults to messages.defaultWindowHours from config, otherwise 48).")
        public var sinceHours: Int?

        @Option(name: .long, help: "Maximum conversations to return (default: 50).")
        public var limit: Int = 50

        @OptionGroup public var contactResolution: ContactResolutionOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            // Throws on an unparseable config: an unreadable exclude list must not read as empty.
            let config = try AIProviderFactory.loadConfigOrThrow()
            let messagesConfig = config?.messages
            let windowHours = sinceHours ?? messagesConfig?.defaultWindowHours ?? 48
            let since = Date().addingTimeInterval(-Double(windowHours) * 3600)
            let excluded = Set(messagesConfig?.excludedThreads ?? [])
            let db = try MessagesDatabase(dbPath: MessagesDatabase.defaultDBPath())
            let (convs, excludedCount) = try db.listConversations(
                since: since,
                limit: limit,
                excluded: excluded,
                contactIndex: MessagesCommand.contactIndex(contactResolution, config: config)
            )
            MessagesAuditLog.record(
                operation: "list",
                params: ["since_hours": "\(windowHours)", "limit": "\(limit)"],
                resultCount: convs.count
            )
            // Envelope v2: `data` is the bare conversations array (matching every
            // other module); the exclude-list signal moves to `warnings`.
            let warnings = excludedCount > 0
                ? ["\(excludedCount) conversation(s) filtered by exclude list"] : nil
            return AgentResult(convs, warnings: warnings)
        }
    }

    // MARK: - Search

    public struct Search: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search message bodies by substring."
        )

        @Argument(help: "Search query (substring match).")
        public var query: String

        @Option(name: .long, help: "Only messages in the last N hours (default: 168 = 1 week).")
        public var sinceHours: Int = 168

        @Option(name: .long, help: "Maximum messages to return (default: 50).")
        public var limit: Int = 50

        @OptionGroup public var contactResolution: ContactResolutionOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let since = Date().addingTimeInterval(-Double(sinceHours) * 3600)
            // Throws on an unparseable config: an unreadable exclude list must not read as empty.
            let config = try AIProviderFactory.loadConfigOrThrow()
            let excluded = Set(config?.messages?.excludedThreads ?? [])
            let db = try MessagesDatabase(dbPath: MessagesDatabase.defaultDBPath())
            let (matches, excludedCount, scanTruncated) = try db.searchMessages(
                query: query,
                since: since,
                limit: limit,
                excluded: excluded,
                contactIndex: MessagesCommand.contactIndex(contactResolution, config: config)
            )
            let payload = MessagesSearchResult(
                matches: matches,
                excludedCount: excludedCount,
                query: query,
                scanTruncated: scanTruncated,
                scannedAttributedCap: MessagesDatabase.searchAttributedScanCap
            )
            MessagesAuditLog.record(
                operation: "search",
                params: ["query": query, "since_hours": "\(sinceHours)", "limit": "\(limit)"],
                resultCount: matches.count
            )
            return .emit(payload, timedOutHint: "")
        }
    }

    // MARK: - Show

    public struct Show: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show messages in a conversation by GUID."
        )

        @Argument(help: "Conversation GUID (from `pippin messages list`).")
        public var conversationId: String

        @Option(name: .long, help: "Maximum messages (default: 50).")
        public var limit: Int = 50

        @OptionGroup public var contactResolution: ContactResolutionOptions

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            // Throws on an unparseable config: an unreadable exclude list must not read as empty.
            let config = try AIProviderFactory.loadConfigOrThrow()
            let excluded = Set(config?.messages?.excludedThreads ?? [])
            let db = try MessagesDatabase(dbPath: MessagesDatabase.defaultDBPath())
            let (conv, messages, truncated) = try db.showConversation(
                conversationId: conversationId,
                limit: limit,
                excluded: excluded,
                contactIndex: MessagesCommand.contactIndex(contactResolution, config: config)
            )
            let payload = MessagesShowResult(conversation: conv, messages: messages, truncated: truncated)
            MessagesAuditLog.record(
                operation: "show",
                params: ["conversation_id": conversationId, "limit": "\(limit)"],
                resultCount: messages.count
            )
            return .emit(payload, timedOutHint: "")
        }
    }

    // MARK: - Send

    public enum SendMode: String, Sendable {
        case draft
        case autonomous
    }

    public struct Send: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "send",
            abstract: "Send a message. Defaults to --draft; autonomous delivery requires triple gate."
        )

        @Option(name: .long, help: "Recipient handle (e.g. +15551234567) or chat GUID.")
        public var to: String

        @Option(name: .long, help: "Message body.")
        public var body: String

        @Flag(name: .long, help: "Do not actually send — just log the draft (default).")
        public var draft: Bool = false

        @Flag(name: .long, help: "Send for real. Requires PIPPIN_AUTONOMOUS_MESSAGES=1 and allowlist.")
        public var autonomous: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if draft, autonomous {
                throw ValidationError("--draft and --autonomous are mutually exclusive.")
            }
        }

        public mutating func execute() async throws -> AgentResult {
            let (payload, warnings) = try MessagesCommand.performSend(
                to: to, body: body, mode: autonomous ? .autonomous : .draft,
                sender: { try MessagesSender.send(to: $0, body: $1) }
            )
            return .emit(payload, timedOutHint: "", extraWarnings: warnings)
        }
    }

    /// Triple gate for a real send: the flag (the caller's `mode`), the
    /// environment variable and the allowlist.
    static func gateAutonomous(recipient: String) throws {
        let envOK = ProcessInfo.processInfo.environment["PIPPIN_AUTONOMOUS_MESSAGES"] == "1"
        guard envOK else { throw MessagesSendError.autonomousNotAuthorized }
        let allow = try AIProviderFactory.loadConfigOrThrow()?.messages?.autonomousAllowlist ?? []
        guard allow.contains(recipient) else {
            throw MessagesSendError.recipientNotAllowed(recipient)
        }
    }

    /// One send with its audit trail. Every path writes a line: `refused` (gate
    /// or guardrail), `draft`, or `attempt` followed by `success`, `failed` or
    /// `outcome_unknown`. The attempt line is written first and must succeed, so
    /// a message can never go out with no record of it.
    ///
    /// `sender` has no default: a test cannot reach Messages by leaving it out.
    static func performSend(
        to: String,
        body: String,
        mode: SendMode,
        gate: (String) throws -> Void = MessagesCommand.gateAutonomous,
        sender: (_ to: String, _ body: String) throws -> MessagesSender.SendResult
    ) throws -> (payload: MessagesSendResult, warnings: [String]) {
        let bodyHash = MessagesAuditLog.hash(body: body)

        func entry(_ outcome: String, sent: Bool?, error: Error? = nil, overrides: [String]? = nil) throws {
            var params = ["mode": mode.rawValue]
            if let error { params["error"] = agentErrorCode(for: error) }
            try MessagesAuditLog.recordOrThrow(
                operation: "send", params: params, recipient: to, bodyHash: bodyHash,
                sent: sent, outcome: outcome, overrides: overrides
            )
        }

        if mode == .autonomous {
            do {
                try gate(to)
            } catch {
                try? entry("refused", sent: false, error: error)
                throw error
            }
        }

        let phi = PHIFilter.scan(body)
        if !phi.isClean {
            let error = MessagesSendError.phiFiltered(phi.flagged)
            try? entry("refused", sent: false, error: error, overrides: phi.flagged)
            throw error
        }

        guard mode == .autonomous else {
            try? entry("draft", sent: false)
            return (MessagesSendResult(
                recipient: to,
                delivered: false,
                mode: mode.rawValue,
                detail: "draft — no delivery attempted",
                bodyHash: bodyHash
            ), [])
        }

        do {
            try entry("attempt", sent: nil)
        } catch {
            throw MessagesSendError.auditLogUnavailable(
                path: MessagesAuditLog.defaultPath(), detail: error.localizedDescription
            )
        }
        let result: MessagesSender.SendResult
        do {
            result = try sender(to, body)
        } catch {
            if case MessagesSendError.timeout = error {
                // May have been delivered: `sent` is left out, not false.
                try? entry("outcome_unknown", sent: nil, error: error)
            } else {
                try? entry("failed", sent: false, error: error)
            }
            throw error
        }
        // The message is out; a failed outcome line cannot undo that, so say so.
        var warnings: [String] = []
        do {
            try entry("success", sent: result.delivered)
        } catch {
            warnings.append(
                "The message was sent, but its outcome could not be written to the audit log at \(MessagesAuditLog.defaultPath()). The log shows only the attempt."
            )
        }
        return (MessagesSendResult(
            recipient: to,
            delivered: result.delivered,
            mode: mode.rawValue,
            detail: result.detail,
            bodyHash: bodyHash
        ), warnings)
    }

    // MARK: - Exclude

    public struct Exclude: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "exclude",
            abstract: "Manage the exclude list (threads hidden from every read).",
            subcommands: [ExcludeList.self, ExcludeAdd.self, ExcludeRemove.self]
        )

        public init() {}
    }

    public struct ExcludeList: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Show the current exclude list."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let threads = try AIProviderFactory.loadConfigOrThrow()?.messages?.excludedThreads ?? []
            return emitExclude(action: "list", threads: threads)
        }
    }

    public struct ExcludeAdd: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a thread GUID to the exclude list."
        )

        @Argument(help: "Thread GUID.")
        public var thread: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let threads = try MessagesCommand.mutateExclude { current in
                current.contains(thread) ? current : current + [thread]
            }
            return emitExclude(action: "add", threads: threads)
        }
    }

    public struct ExcludeRemove: AgentCommand {
        public static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a thread GUID from the exclude list."
        )

        @Argument(help: "Thread GUID.")
        public var thread: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func execute() async throws -> AgentResult {
            let threads = try MessagesCommand.mutateExclude { current in
                current.filter { $0 != thread }
            }
            return emitExclude(action: "remove", threads: threads)
        }
    }

    // MARK: - Helpers

    static func mutateExclude(_ mutate: ([String]) -> [String]) throws -> [String] {
        // Throws before saving when the file exists but does not parse: writing
        // back a blank config would wipe every other setting in it.
        var config = try AIProviderFactory.loadConfigOrThrow() ?? PippinConfig()
        var messages = config.messages ?? PippinConfig.MessagesConfig()
        let current = messages.excludedThreads ?? []
        let updated = mutate(current)
        messages.excludedThreads = updated
        config.messages = messages
        try AIProviderFactory.saveConfig(config)
        return updated
    }
}

private func emitExclude(action: String, threads: [String]) -> AgentResult {
    let payload = MessagesExcludeResult(action: action, threads: threads)
    return .emit(payload, timedOutHint: "")
}
