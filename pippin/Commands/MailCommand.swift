import ArgumentParser
import Foundation

public struct MailCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Interact with Apple Mail.",
        subcommands: [Accounts.self, Search.self, List.self, Show.self, Read.self, Mark.self, Move.self, Send.self]
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
            } else {
                let rows = accounts.map { [$0.name, $0.email] }
                print(TextFormatter.table(headers: ["NAME", "EMAIL"], rows: rows, columnWidths: [25, 50]))
            }
        }
    }

    // MARK: - Search

    public struct Search: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search messages by subject, sender, or body."
        )

        @Argument(help: "Search query (case-insensitive, matches subject/sender/body).")
        public var query: String

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @Option(name: .long, help: "Maximum number of results to return (default: 10).")
        public var limit: Int = 10

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let messages = try MailBridge.searchMessages(
                query: query,
                account: account,
                limit: limit
            )
            if output.isJSON {
                try printJSON(messages)
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

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func run() async throws {
            let messages = try MailBridge.listMessages(
                account: account,
                mailbox: mailbox,
                unread: unread,
                limit: limit
            )
            if output.isJSON {
                try printJSON(messages)
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
            if output.isJSON {
                try printJSON(message)
            } else {
                let fields: [(String, String)] = [
                    ("From", message.from),
                    ("To", message.to.joined(separator: ", ")),
                    ("Date", TextFormatter.compactDate(message.date)),
                    ("Subject", message.subject),
                    ("Mailbox", "\(message.account) / \(message.mailbox)"),
                    ("Body", message.body ?? "(no body)"),
                ]
                print(TextFormatter.card(fields: fields))
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
            } else {
                let detail = result.details.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: detail))
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
            } else {
                let detail = result.details.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: detail))
            }
        }
    }

    // MARK: - Send

    public struct Send: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "send",
            abstract: "Send an email message."
        )

        @Option(name: .long, help: "Recipient email address.")
        public var to: String

        @Option(name: .long, help: "Message subject.")
        public var subject: String

        @Option(name: .long, help: "Message body text.")
        public var body: String

        @Option(name: .long, help: "CC recipient email address.")
        public var cc: String?

        @Option(name: .long, help: "Sending account name.")
        public var from: String?

        @Option(name: .long, help: "Path to file to attach.")
        public var attach: String?

        @Flag(name: .long, help: "Print what would happen without sending.")
        public var dryRun: Bool = false

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            let emailPattern = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#
            guard to.range(of: emailPattern, options: .regularExpression) != nil else {
                throw ValidationError("--to does not look like a valid email address.")
            }
            if let ccAddr = cc {
                guard ccAddr.range(of: emailPattern, options: .regularExpression) != nil else {
                    throw ValidationError("--cc does not look like a valid email address.")
                }
            }
            if let attachPath = attach {
                guard FileManager.default.fileExists(atPath: attachPath) else {
                    let filename = URL(fileURLWithPath: attachPath).lastPathComponent
                    throw ValidationError("Attachment file not found: \(filename)")
                }
            }
        }

        public mutating func run() async throws {
            let result = try MailBridge.sendMessage(
                to: to,
                subject: subject,
                body: body,
                cc: cc,
                from: from,
                attachmentPath: attach,
                dryRun: dryRun
            )
            if output.isJSON {
                try printJSON(result)
            } else {
                let detail = result.details.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
                print(TextFormatter.actionResult(success: result.success, action: result.action, details: detail))
            }
        }
    }
}

// MARK: - Shared Helpers

/// Print a table of messages in text format (used by List and Search).
private func printMessageTable(_ messages: [MailMessage]) {
    let rows = messages.map { msg in
        [
            TextFormatter.truncate(msg.id, to: 8),
            TextFormatter.compactDate(msg.date),
            TextFormatter.truncate(msg.from, to: 18),
            TextFormatter.truncate(msg.subject, to: 30),
            msg.read ? "Y" : "N",
        ]
    }
    print(TextFormatter.table(
        headers: ["ID", "DATE", "FROM", "SUBJECT", "READ"],
        rows: rows,
        columnWidths: [10, 18, 20, 32, 4]
    ))
}
