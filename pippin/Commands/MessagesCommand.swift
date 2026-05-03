import ArgumentParser
import Foundation

public struct MessagesCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "messages",
        abstract: "Read Apple Messages conversations and send (draft by default).",
        subcommands: [List.self, Search.self, Show.self, Send.self, Exclude.self]
    )

    public init() {}

    // MARK: - List

    public struct List: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List recent conversations (most recent first)."
        )

        @Option(name: .long, help: "Only conversations with a message in the last N hours (defaults to messages.defaultWindowHours from config, otherwise 48).")
        public var sinceHours: Int?

        @Option(name: .long, help: "Maximum conversations to return (default: 50).")
        public var limit: Int = 50

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let config = AIProviderFactory.loadConfig()?.messages
            let windowHours = sinceHours ?? config?.defaultWindowHours ?? 48
            let since = Date().addingTimeInterval(-Double(windowHours) * 3600)
            let excluded = Set(config?.excludedThreads ?? [])
            let db = try MessagesDatabase(dbPath: MessagesDatabase.defaultDBPath())
            let (convs, excludedCount) = try db.listConversations(
                since: since,
                limit: limit,
                excluded: excluded
            )
            let payload = MessagesListResult(
                conversations: convs,
                excludedCount: excludedCount,
                windowHours: windowHours
            )
            try? MessagesAuditLog.record(
                operation: "list",
                params: ["since_hours": "\(windowHours)", "limit": "\(limit)"],
                resultCount: convs.count
            )
            try output.emit(payload, timedOutHint: "") {
                printConversationList(payload)
            }
        }

        private func printConversationList(_ payload: MessagesListResult) {
            if payload.conversations.isEmpty {
                print("No conversations in the last \(payload.windowHours ?? 48) hours.")
                return
            }
            for conv in payload.conversations {
                let label = conv.displayName ?? conv.participants.map(\.handle).joined(separator: ", ")
                let when = conv.lastMessageAt ?? "-"
                let unread = conv.unreadCount > 0 ? "  (\(conv.unreadCount) unread)" : ""
                print("• \(when)  \(label)\(unread)")
                if let preview = conv.lastMessagePreview {
                    print("    \(preview)")
                }
            }
            if payload.excludedCount > 0 {
                print("")
                print("(\(payload.excludedCount) conversation(s) filtered by exclude list.)")
            }
        }
    }

    // MARK: - Search

    public struct Search: AsyncParsableCommand {
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

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let since = Date().addingTimeInterval(-Double(sinceHours) * 3600)
            let excluded = Set(AIProviderFactory.loadConfig()?.messages?.excludedThreads ?? [])
            let db = try MessagesDatabase(dbPath: MessagesDatabase.defaultDBPath())
            let (matches, excludedCount) = try db.searchMessages(
                query: query,
                since: since,
                limit: limit,
                excluded: excluded
            )
            let payload = MessagesSearchResult(
                matches: matches,
                excludedCount: excludedCount,
                query: query
            )
            try? MessagesAuditLog.record(
                operation: "search",
                params: ["query": query, "since_hours": "\(sinceHours)", "limit": "\(limit)"],
                resultCount: matches.count
            )
            try output.emit(payload, timedOutHint: "") {
                printSearchResults(payload)
            }
        }

        private func printSearchResults(_ payload: MessagesSearchResult) {
            if payload.matches.isEmpty {
                print("No messages matching '\(payload.query)'.")
                return
            }
            for m in payload.matches {
                let who = m.isFromMe ? "me" : (m.fromHandle ?? "unknown")
                let text = m.text ?? "(no text)"
                print("• \(m.date)  \(who): \(MessagesDatabase.preview(text))")
            }
        }
    }

    // MARK: - Show

    public struct Show: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show messages in a conversation by GUID."
        )

        @Argument(help: "Conversation GUID (from `pippin messages list --format json`).")
        public var conversationId: String

        @Option(name: .long, help: "Maximum messages (default: 50).")
        public var limit: Int = 50

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let db = try MessagesDatabase(dbPath: MessagesDatabase.defaultDBPath())
            let (conv, messages, truncated) = try db.showConversation(
                conversationId: conversationId,
                limit: limit
            )
            let payload = MessagesShowResult(conversation: conv, messages: messages, truncated: truncated)
            try? MessagesAuditLog.record(
                operation: "show",
                params: ["conversation_id": conversationId, "limit": "\(limit)"],
                resultCount: messages.count
            )
            try output.emit(payload, timedOutHint: "") {
                printShow(payload)
            }
        }

        private func printShow(_ payload: MessagesShowResult) {
            let label = payload.conversation.displayName
                ?? payload.conversation.participants.map(\.handle).joined(separator: ", ")
            print("Thread: \(label)")
            print("")
            for m in payload.messages {
                let who = m.isFromMe ? "me" : (m.fromHandle ?? "unknown")
                let text = m.text ?? "(no text)"
                print("[\(m.date)] \(who): \(text)")
            }
            if payload.truncated {
                print("")
                print("(older messages truncated — re-run with --limit N)")
            }
        }
    }

    // MARK: - Send

    public enum SendMode: String, Sendable {
        case draft
        case autonomous
    }

    public struct Send: AsyncParsableCommand {
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

        public mutating func run() async throws {
            let mode: SendMode = autonomous ? .autonomous : .draft
            let bodyHash = MessagesAuditLog.hash(body: body)

            if mode == .autonomous {
                try gateAutonomous(recipient: to)
            }

            let phi = PHIFilter.scan(body)
            if !phi.isClean {
                MessagesAuditLog.record(
                    operation: "send",
                    params: ["mode": mode.rawValue],
                    recipient: to,
                    bodyHash: bodyHash,
                    sent: false,
                    overrides: phi.flagged
                )
                throw MessagesSendError.phiFiltered(phi.flagged)
            }

            let payload: MessagesSendResult = try {
                switch mode {
                case .autonomous:
                    let result = try MessagesSender.send(to: to, body: body)
                    return MessagesSendResult(
                        recipient: to,
                        delivered: result.delivered,
                        mode: mode.rawValue,
                        detail: result.detail,
                        bodyHash: bodyHash
                    )
                case .draft:
                    return MessagesSendResult(
                        recipient: to,
                        delivered: false,
                        mode: mode.rawValue,
                        detail: "draft — no delivery attempted",
                        bodyHash: bodyHash
                    )
                }
            }()

            MessagesAuditLog.record(
                operation: "send",
                params: ["mode": mode.rawValue],
                recipient: to,
                bodyHash: bodyHash,
                sent: payload.delivered
            )

            try output.emit(payload, timedOutHint: "") {
                if payload.delivered {
                    print("Sent to \(payload.recipient). hash=\(bodyHash.prefix(12))…")
                } else {
                    print("Draft (mode=\(mode.rawValue)) for \(payload.recipient). hash=\(bodyHash.prefix(12))…")
                    print("Not delivered. Re-run with --autonomous to send (requires env + allowlist).")
                }
            }
        }

        private func gateAutonomous(recipient: String) throws {
            let envOK = ProcessInfo.processInfo.environment["PIPPIN_AUTONOMOUS_MESSAGES"] == "1"
            guard envOK else { throw MessagesSendError.autonomousNotAuthorized }
            let allow = AIProviderFactory.loadConfig()?.messages?.autonomousAllowlist ?? []
            guard allow.contains(recipient) else {
                throw MessagesSendError.recipientNotAllowed(recipient)
            }
        }
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

    public struct ExcludeList: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "Show the current exclude list."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() throws {
            let threads = AIProviderFactory.loadConfig()?.messages?.excludedThreads ?? []
            try emitExclude(action: "list", threads: threads, output: output)
        }
    }

    public struct ExcludeAdd: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a thread GUID to the exclude list."
        )

        @Argument(help: "Thread GUID.")
        public var thread: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() throws {
            let threads = try MessagesCommand.mutateExclude { current in
                current.contains(thread) ? current : current + [thread]
            }
            try emitExclude(action: "add", threads: threads, output: output)
        }
    }

    public struct ExcludeRemove: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a thread GUID from the exclude list."
        )

        @Argument(help: "Thread GUID.")
        public var thread: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() throws {
            let threads = try MessagesCommand.mutateExclude { current in
                current.filter { $0 != thread }
            }
            try emitExclude(action: "remove", threads: threads, output: output)
        }
    }

    // MARK: - Helpers

    static func mutateExclude(_ mutate: ([String]) -> [String]) throws -> [String] {
        var config = AIProviderFactory.loadConfig() ?? PippinConfig()
        var messages = config.messages ?? PippinConfig.MessagesConfig()
        let current = messages.excludedThreads ?? []
        let updated = mutate(current)
        messages.excludedThreads = updated
        config.messages = messages
        try AIProviderFactory.saveConfig(config)
        return updated
    }
}

private func emitExclude(action: String, threads: [String], output: OutputOptions) throws {
    let payload = MessagesExcludeResult(action: action, threads: threads)
    try output.emit(payload, timedOutHint: "") {
        if action == "list", threads.isEmpty {
            print("Exclude list is empty.")
        } else if action == "list" {
            print("Excluded thread(s):")
            threads.forEach { print("  • \($0)") }
        } else {
            print("Exclude list now contains \(threads.count) thread(s).")
        }
    }
}
