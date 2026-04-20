import ArgumentParser
import Foundation

public struct MailCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Interact with Apple Mail.",
        subcommands: [Accounts.self, Mailboxes.self, Search.self, List.self, Activity.self, Show.self, Read.self, Mark.self, Move.self, Send.self, Attachments.self, Reply.self, Forward.self, MailIndex.self, MailSanitize.self, MailExtract.self, MailTriage.self]
    )

    public init() {}

    // MARK: - Accounts

    public struct Accounts: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "accounts",
            abstract: "List configured Mail accounts."
        )

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let accounts = try MailBridge.listAccounts()
            if output.isJSON {
                try printJSON(accounts)
            } else if output.isAgent {
                try printAgentJSON(accounts)
            } else {
                let rows = accounts.map { [$0.name, $0.email] }
                print(TextFormatter.table(headers: ["NAME", "EMAIL"], rows: rows, columnWidths: [25, 50]))
            }
        }
    }

    // MARK: - Mailboxes

    public struct Mailboxes: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "mailboxes",
            abstract: "List mailboxes per account."
        )

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let mailboxes = try MailBridge.listMailboxes(account: account)
            if output.isJSON {
                try printJSON(mailboxes)
            } else if output.isAgent {
                try printAgentJSON(mailboxes)
            } else {
                let rows = mailboxes.map { [$0.account, $0.name, "\($0.messageCount)", "\($0.unreadCount)"] }
                print(TextFormatter.table(
                    headers: ["ACCOUNT", "MAILBOX", "MESSAGES", "UNREAD"],
                    rows: rows,
                    columnWidths: [20, 25, 10, 8]
                ))
            }
        }
    }

    // MARK: - Search

    public struct Search: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search messages by subject or sender. Use --body for body content."
        )

        @Argument(help: "Search query (case-insensitive, matches subject/sender).")
        public var query: String

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @Option(name: .long, help: "Restrict search to a single mailbox.")
        public var mailbox: String?

        @Flag(name: .long, help: "Include message body in search (slower).")
        public var body: Bool = false

        @Option(name: .long, help: "Only include messages on or after this date (YYYY-MM-DD).")
        public var after: String?

        @Option(name: .long, help: "Only include messages on or before this date (YYYY-MM-DD).")
        public var before: String?

        @Option(name: .long, help: "Filter by recipient email address.")
        public var to: String?

        @Flag(name: .long, help: "Print search diagnostics (accounts/mailboxes scanned, messages examined).")
        public var verbose: Bool = false

        @Option(name: .long, help: "Maximum number of results to return (default: 10).")
        public var limit: Int = 10

        @Option(name: .long, help: "Page number (1-based, with --limit as page size).")
        public var page: Int = 1

        @Flag(name: .long, help: "Use semantic (embedding-based) search. Requires running `mail index` first.")
        public var semantic: Bool = false

        @Option(name: .customLong("embedding-model"), help: "Embedding model for semantic search (default: nomic-embed-text).")
        public var embeddingModel: String?

        @Option(name: .customLong("ollama-url"), help: "Ollama base URL for semantic search.")
        public var ollamaUrl: String?

        @Option(name: .long, help: "Embedding provider for semantic search (only 'ollama' supported).")
        public var provider: String = "ollama"

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard page >= 1 else {
                throw ValidationError("--page must be 1 or greater.")
            }
            if let after = after {
                guard isValidDate(after) else {
                    throw ValidationError("--after must be in YYYY-MM-DD format, got: \(after)")
                }
            }
            if let before = before {
                guard isValidDate(before) else {
                    throw ValidationError("--before must be in YYYY-MM-DD format, got: \(before)")
                }
            }
        }

        public mutating func run() async throws {
            if semantic {
                guard provider == "ollama" else {
                    throw MailAIError.unsupportedEmbeddingProvider(provider)
                }
                let baseURL = ollamaUrl ?? "http://localhost:11434"
                let model = embeddingModel ?? "nomic-embed-text"
                let embedProvider = OllamaEmbeddingProvider(baseURL: baseURL, model: model)
                let store = try EmbeddingStore()

                let messages = try SemanticSearch.search(
                    query: query,
                    store: store,
                    provider: embedProvider,
                    limit: limit
                )

                if output.isJSON {
                    try printJSON(messages)
                } else if output.isAgent {
                    try printAgentJSON(messages)
                } else {
                    printMessageTable(messages)
                }
                return
            }

            let messages = try MailBridge.searchMessages(
                query: query,
                account: account,
                mailbox: mailbox,
                searchBody: body,
                limit: limit,
                offset: (page - 1) * limit,
                after: after,
                before: before,
                to: to,
                verbose: verbose
            )
            if output.isJSON {
                try printJSON(messages)
            } else if output.isAgent {
                try printAgentJSON(messages)
            } else {
                printMessageTable(messages)
            }
        }
    }

    // MARK: - List

    public struct List: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List messages. Defaults to INBOX, all messages, limit 20."
        )

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @Option(name: .long, help: "Mailbox name (default: INBOX).")
        public var mailbox: String = "INBOX"

        @Flag(name: .long, help: "Only show unread messages.")
        public var unread: Bool = false

        @Option(name: .long, help: "Maximum number of messages to return.")
        public var limit: Int = 20

        @Option(name: .long, help: "Page number (1-based, with --limit as page size).")
        public var page: Int = 1

        @Option(
            name: .long,
            help: "Include a plain-text body preview of up to N chars per message (e.g. --preview 200 for agent scan workflows to avoid N+1 mail_show calls). Forces a per-message IMAP fetch — bumps the timeout to 60s."
        )
        public var preview: Int?

        @Flag(name: .long, help: "Include AI-generated one-liner summaries per message (uses batch AI calls).")
        public var summarize: Bool = false

        @Option(name: .customLong("summarize-provider"), help: "AI provider for summaries.")
        public var summarizeProvider: String?

        @Option(name: .customLong("summarize-model"), help: "Model for summaries.")
        public var summarizeModel: String?

        @Option(name: .customLong("summarize-api-key"), help: "API key for summary provider.")
        public var summarizeApiKey: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard page >= 1 else {
                throw ValidationError("--page must be 1 or greater.")
            }
            if let preview, preview <= 0 {
                throw ValidationError("--preview must be a positive integer (chars).")
            }
        }

        public mutating func run() async throws {
            let messages = try MailBridge.listMessages(
                account: account,
                mailbox: mailbox,
                unread: unread,
                limit: limit,
                offset: (page - 1) * limit,
                preview: preview
            )

            if summarize {
                let aiProvider = try AIProviderFactory.make(
                    providerFlag: summarizeProvider, modelFlag: summarizeModel, apiKeyFlag: summarizeApiKey
                )
                let triaged = try TriageEngine.triageBatchForSummaries(messages: messages, provider: aiProvider)
                let triageMap = Dictionary(triaged.map { ($0.compoundId, $0.oneLiner) }, uniquingKeysWith: { first, _ in first })

                if triageMap.count < messages.count {
                    let missing = messages.count - triageMap.count
                    fputs("Warning: AI summary unavailable for \(missing) message(s). Use --format json for details.\n", stderr)
                }

                struct MessageWithSummary: Codable {
                    let message: MailMessage
                    let summary: String
                }
                let withSummaries = messages.map { MessageWithSummary(message: $0, summary: triageMap[$0.id] ?? "(summary unavailable)") }

                if output.isJSON {
                    try printJSON(withSummaries)
                } else if output.isAgent {
                    try printAgentJSON(withSummaries)
                } else {
                    let rows = messages.map { msg in
                        [
                            TextFormatter.truncate(msg.id, to: 8),
                            TextFormatter.compactDate(msg.date),
                            TextFormatter.truncate(msg.from, to: 18),
                            TextFormatter.truncate(msg.subject, to: 24),
                            msg.read ? "Y" : "N",
                            TextFormatter.truncate(triageMap[msg.id] ?? "(summary unavailable)", to: 40),
                        ]
                    }
                    print(TextFormatter.table(
                        headers: ["ID", "DATE", "FROM", "SUBJECT", "READ", "SUMMARY"],
                        rows: rows,
                        columnWidths: [10, 18, 20, 26, 4, 42]
                    ))
                }
            } else if output.isJSON {
                try printJSON(messages)
            } else if output.isAgent {
                try printAgentJSON(messages)
            } else {
                printMessageTable(messages)
            }
        }
    }

    // MARK: - Show (formerly Read)

    public struct Show: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a message by its compound id or subject search."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String?

        @Option(name: .long, help: "Find first message matching this subject and show it.")
        public var subject: String?

        @Flag(name: .long, help: "Scan message body for prompt injection patterns before display.")
        public var sanitize: Bool = false

        @Flag(name: .long, help: "Include AI-assisted scan (requires --sanitize).")
        public var aiAssistedScan: Bool = false

        @Option(name: .long, help: "AI provider for --ai-assisted-scan.")
        public var sanitizeProvider: String?

        @Option(name: .customLong("sanitize-model"), help: "Model for AI-assisted scan.")
        public var sanitizeModel: String?

        @Option(name: .customLong("sanitize-api-key"), help: "API key for Claude provider (scan).")
        public var sanitizeApiKey: String?

        @Flag(name: .long, help: "Include an AI-generated summary.")
        public var summarize: Bool = false

        @Option(name: .customLong("summarize-provider"), help: "AI provider for summary.")
        public var summarizeProvider: String?

        @Option(name: .customLong("summarize-model"), help: "Model for summary.")
        public var summarizeModel: String?

        @Option(name: .customLong("summarize-api-key"), help: "API key for summary provider.")
        public var summarizeApiKey: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if messageId != nil, subject != nil {
                throw ValidationError("Provide either a message ID or --subject, not both.")
            }
            if messageId == nil, subject == nil {
                throw ValidationError("Provide a message ID or --subject.")
            }
        }

        public mutating func run() async throws {
            let compoundId: String
            if let subject = subject {
                let results = try MailBridge.searchMessages(query: subject, limit: 1)
                guard let first = results.first else {
                    throw ValidationError("No message found matching subject: \(subject)")
                }
                compoundId = first.id
            } else {
                compoundId = messageId!
            }

            let message = try MailBridge.readMessage(compoundId: compoundId)

            if summarize {
                let summaryProvider = try AIProviderFactory.make(
                    providerFlag: summarizeProvider, modelFlag: summarizeModel, apiKeyFlag: summarizeApiKey
                )
                let summary = try TriageEngine.summarizeMessage(message: message, provider: summaryProvider)

                if output.isJSON || output.isAgent {
                    struct ShowWithSummary: Codable {
                        let message: MailMessage
                        let summary: String
                    }
                    let combined = ShowWithSummary(message: message, summary: summary)
                    if output.isJSON {
                        try printJSON(combined)
                    } else {
                        try printAgentJSON(combined)
                    }
                } else {
                    var fields: [(String, String)] = [
                        ("From", message.from),
                        ("To", message.to.joined(separator: ", ")),
                        ("Date", TextFormatter.compactDate(message.date)),
                        ("Subject", message.subject),
                        ("Mailbox", "\(message.account) / \(message.mailbox)"),
                    ]
                    if let size = message.size {
                        fields.append(("Size", TextFormatter.fileSize(size)))
                    }
                    if let atts = message.attachments, !atts.isEmpty {
                        let attStr = atts.map { "\($0.name) (\($0.mimeType), \(TextFormatter.fileSize($0.size)))" }
                            .joined(separator: "\n")
                        fields.append(("Attachments", attStr))
                    }
                    fields.append(("Body", message.body ?? "(no body)"))
                    print(TextFormatter.card(fields: fields))
                    print("")
                    print("Summary: \(summary)")
                }
            } else if sanitize {
                let body = message.body ?? ""
                let scanResult: ScanResult
                if aiAssistedScan {
                    let aiProvider = try AIProviderFactory.make(
                        providerFlag: sanitizeProvider, modelFlag: sanitizeModel, apiKeyFlag: sanitizeApiKey
                    )
                    scanResult = try PromptInjectionScanner.scanWithAI(text: body, provider: aiProvider)
                } else {
                    scanResult = PromptInjectionScanner.scan(text: body)
                }

                if output.isJSON || output.isAgent {
                    struct ShowWithScan: Codable {
                        let message: MailMessage
                        let scan: ScanResult
                    }
                    let combined = ShowWithScan(message: message, scan: scanResult)
                    if output.isJSON {
                        try printJSON(combined)
                    } else {
                        try printAgentJSON(combined)
                    }
                } else {
                    var fields: [(String, String)] = [
                        ("From", message.from),
                        ("To", message.to.joined(separator: ", ")),
                        ("Date", TextFormatter.compactDate(message.date)),
                        ("Subject", message.subject),
                        ("Mailbox", "\(message.account) / \(message.mailbox)"),
                    ]
                    if let size = message.size {
                        fields.append(("Size", TextFormatter.fileSize(size)))
                    }
                    if let atts = message.attachments, !atts.isEmpty {
                        let attStr = atts.map { "\($0.name) (\($0.mimeType), \(TextFormatter.fileSize($0.size)))" }
                            .joined(separator: "\n")
                        fields.append(("Attachments", attStr))
                    }
                    fields.append(("Body", scanResult.sanitizedBody.isEmpty ? "(no body)" : scanResult.sanitizedBody))
                    print(TextFormatter.card(fields: fields))
                    print("")
                    print("Risk level: \(scanResult.riskLevel.rawValue.uppercased())")
                    print("Threats found: \(scanResult.threats.count)")
                    if !scanResult.threats.isEmpty {
                        for threat in scanResult.threats {
                            print("  [\(threat.category.rawValue)] confidence=\(String(format: "%.2f", threat.confidence)): \(threat.matchedText)")
                        }
                    }
                }
            } else {
                if output.isJSON {
                    try printJSON(message)
                } else if output.isAgent {
                    try printAgentJSON(message)
                } else {
                    var fields: [(String, String)] = [
                        ("From", message.from),
                        ("To", message.to.joined(separator: ", ")),
                        ("Date", TextFormatter.compactDate(message.date)),
                        ("Subject", message.subject),
                        ("Mailbox", "\(message.account) / \(message.mailbox)"),
                    ]
                    if let size = message.size {
                        fields.append(("Size", TextFormatter.fileSize(size)))
                    }
                    if let atts = message.attachments, !atts.isEmpty {
                        let attStr = atts.map { "\($0.name) (\($0.mimeType), \(TextFormatter.fileSize($0.size)))" }
                            .joined(separator: "\n")
                        fields.append(("Attachments", attStr))
                    }
                    fields.append(("Body", message.body ?? "(no body)"))
                    print(TextFormatter.card(fields: fields))
                }
            }
        }
    }

    // MARK: - Read (hidden alias for backward compat)

    public struct Read: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "read",
            abstract: "Read a message (use 'show' instead).",
            shouldDisplay: false
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            var show = Show()
            show.messageId = messageId
            show.output = output
            try await show.run()
        }
    }

    // MARK: - Mark

    public struct Mark: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "mark",
            abstract: "Mark a message as read or unread."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Flag(name: .long, help: "Mark as read.")
        public var read: Bool = false

        @Flag(name: .long, help: "Mark as unread.")
        public var unread: Bool = false

        @Flag(name: .long, help: "Print what would happen without making changes.")
        public var dryRun: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard read != unread else {
                throw ValidationError("Specify exactly one of --read or --unread.")
            }
        }

        public mutating func run() async throws {
            let result = try MailBridge.markMessage(
                compoundId: messageId,
                read: read,
                dryRun: dryRun
            )
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Move

    public struct Move: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "move",
            abstract: "Move a message to another mailbox."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Option(name: .long, help: "Destination mailbox name.")
        public var to: String

        @Flag(name: .long, help: "Print what would happen without making changes.")
        public var dryRun: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let result = try MailBridge.moveMessage(
                compoundId: messageId,
                toMailbox: to,
                dryRun: dryRun
            )
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Send

    public struct Send: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "send",
            abstract: "Send an email message."
        )

        @Option(name: .long, parsing: .unconditionalSingleValue, help: "Recipient email address (repeatable).")
        public var to: [String] = []

        @Option(name: .long, help: "Message subject.")
        public var subject: String

        @Option(name: .long, help: "Message body text.")
        public var body: String

        @Option(name: .customLong("cc"), parsing: .unconditionalSingleValue, help: "CC recipient (repeatable).")
        public var cc: [String] = []

        @Option(name: .customLong("bcc"), parsing: .unconditionalSingleValue, help: "BCC recipient (repeatable).")
        public var bcc: [String] = []

        @Option(name: .long, help: "Sending account name.")
        public var from: String?

        @Option(name: .customLong("attach"), parsing: .unconditionalSingleValue, help: "Path to file to attach (repeatable).")
        public var attach: [String] = []

        @Flag(name: .long, help: "Print what would happen without sending.")
        public var dryRun: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard !to.isEmpty else {
                throw ValidationError("At least one --to address is required.")
            }
            try validateEmailAddresses(to, field: "to")
            try validateEmailAddresses(cc, field: "cc")
            try validateEmailAddresses(bcc, field: "bcc")
            try validateAttachmentPaths(attach)
        }

        public mutating func run() async throws {
            let result = try MailBridge.sendMessage(
                to: to,
                subject: subject,
                body: body,
                cc: cc,
                bcc: bcc,
                from: from,
                attachmentPaths: attach,
                dryRun: dryRun
            )
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Attachments

    public struct Attachments: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "attachments",
            abstract: "List (and optionally save) attachments from a message."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Option(name: .long, help: "Save attachments to this directory.")
        public var saveDir: String?

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            if let dir = saveDir {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                    throw ValidationError("--save-dir does not exist or is not a directory: \(dir)")
                }
                guard FileManager.default.isWritableFile(atPath: dir) else {
                    throw ValidationError("--save-dir is not writable: \(dir)")
                }
            }
        }

        public mutating func run() async throws {
            let attachments = try MailBridge.listAttachments(compoundId: messageId, saveDir: saveDir)
            if output.isJSON {
                try printJSON(attachments)
            } else if output.isAgent {
                try printAgentJSON(attachments)
            } else if attachments.isEmpty {
                print("No attachments.")
            } else {
                let rows = attachments.map { att -> [String] in
                    let saved = att.savedPath.map { "  → \($0)" } ?? ""
                    return [att.name, att.mimeType, TextFormatter.fileSize(att.size), saved]
                }
                print(TextFormatter.table(
                    headers: ["NAME", "TYPE", "SIZE", "SAVED"],
                    rows: rows,
                    columnWidths: [30, 25, 10, 40]
                ))
            }
        }
    }

    // MARK: - Reply

    public struct Reply: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "reply",
            abstract: "Reply to a message."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Option(name: .long, help: "Reply body text.")
        public var body: String

        @Option(name: .customLong("to"), parsing: .unconditionalSingleValue, help: "Override reply-to address (repeatable; defaults to original sender).")
        public var to: [String] = []

        @Option(name: .customLong("cc"), parsing: .unconditionalSingleValue, help: "CC recipient (repeatable).")
        public var cc: [String] = []

        @Option(name: .customLong("bcc"), parsing: .unconditionalSingleValue, help: "BCC recipient (repeatable).")
        public var bcc: [String] = []

        @Option(name: .long, help: "Sending account name.")
        public var from: String?

        @Option(name: .customLong("attach"), parsing: .unconditionalSingleValue, help: "Path to file to attach (repeatable).")
        public var attach: [String] = []

        @Flag(name: .long, help: "Print what would happen without sending.")
        public var dryRun: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            try validateEmailAddresses(to, field: "to")
            try validateEmailAddresses(cc, field: "cc")
            try validateEmailAddresses(bcc, field: "bcc")
            try validateAttachmentPaths(attach)
        }

        public mutating func run() async throws {
            let result = try MailBridge.replyToMessage(
                compoundId: messageId,
                body: body,
                to: to.isEmpty ? nil : to,
                cc: cc,
                bcc: bcc,
                from: from,
                attachmentPaths: attach,
                dryRun: dryRun
            )
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }

    // MARK: - Forward

    public struct Forward: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "forward",
            abstract: "Forward a message."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        @Option(name: .customLong("to"), parsing: .unconditionalSingleValue, help: "Recipient address (repeatable).")
        public var to: [String] = []

        @Option(name: .long, help: "Additional body text (prepended before forwarded content).")
        public var body: String = ""

        @Option(name: .customLong("cc"), parsing: .unconditionalSingleValue, help: "CC recipient (repeatable).")
        public var cc: [String] = []

        @Option(name: .customLong("bcc"), parsing: .unconditionalSingleValue, help: "BCC recipient (repeatable).")
        public var bcc: [String] = []

        @Option(name: .long, help: "Sending account name.")
        public var from: String?

        @Option(name: .customLong("attach"), parsing: .unconditionalSingleValue, help: "Path to file to attach (repeatable).")
        public var attach: [String] = []

        @Flag(name: .long, help: "Print what would happen without sending.")
        public var dryRun: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard !to.isEmpty else {
                throw ValidationError("At least one --to address is required.")
            }
            try validateEmailAddresses(to, field: "to")
            try validateEmailAddresses(cc, field: "cc")
            try validateEmailAddresses(bcc, field: "bcc")
            try validateAttachmentPaths(attach)
        }

        public mutating func run() async throws {
            let result = try MailBridge.forwardMessage(
                compoundId: messageId,
                to: to,
                body: body,
                cc: cc,
                bcc: bcc,
                from: from,
                attachmentPaths: attach,
                dryRun: dryRun
            )
            if output.isJSON {
                try printJSON(result)
            } else if output.isAgent {
                try printAgentJSON(result)
            } else {
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: result.details))
            }
        }
    }
}

// MARK: - Shared Helpers

private let emailPattern = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#

private let datePattern = #"^\d{4}-\d{2}-\d{2}$"#

private func isValidDate(_ s: String) -> Bool {
    guard s.range(of: datePattern, options: .regularExpression) != nil else { return false }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.date(from: s) != nil
}

private func validateEmailAddresses(_ addrs: [String], field: String) throws {
    for addr in addrs {
        guard addr.range(of: emailPattern, options: .regularExpression) != nil else {
            throw ValidationError("--\(field) '\(addr)' does not look like a valid email address.")
        }
    }
}

private func validateAttachmentPaths(_ paths: [String]) throws {
    for path in paths {
        guard FileManager.default.fileExists(atPath: path) else {
            let filename = URL(fileURLWithPath: path).lastPathComponent
            throw ValidationError("Attachment file not found: \(filename)")
        }
    }
}

/// Print a table of messages in text format (used by List and Search).
func printMessageTable(_ messages: [MailMessage]) {
    let rows = messages.map { msg in
        [
            TextFormatter.truncate(msg.id, to: 8),
            TextFormatter.compactDate(msg.date),
            TextFormatter.truncate(msg.from, to: 18),
            TextFormatter.truncate(msg.subject, to: 24),
            msg.read ? "Y" : "N",
            msg.hasAttachment == true ? "A" : " ",
            msg.size.map { TextFormatter.fileSize($0) } ?? "",
        ]
    }
    print(TextFormatter.table(
        headers: ["ID", "DATE", "FROM", "SUBJECT", "READ", "ATT", "SIZE"],
        rows: rows,
        columnWidths: [10, 18, 20, 26, 4, 3, 8]
    ))
}
