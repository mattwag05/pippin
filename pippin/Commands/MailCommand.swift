import ArgumentParser
import Foundation

/// Encode and print a JSON value to stdout with pretty-printing and sorted keys.
private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8)!)
}

public struct MailCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Interact with Apple Mail.",
        subcommands: [Accounts.self, Search.self, List.self, Read.self, Mark.self, Move.self, Send.self]
    )

    public init() {}

    public struct Accounts: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "accounts",
            abstract: "List configured Mail accounts."
        )

        public init() {}

        public mutating func run() async throws {
            let accounts = try MailBridge.listAccounts()
            try printJSON(accounts)
        }
    }

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

        public init() {}

        public mutating func run() async throws {
            let messages = try MailBridge.searchMessages(
                query: query,
                account: account,
                limit: limit
            )
            try printJSON(messages)
        }
    }

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
            try printJSON(result)
        }
    }

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

        public init() {}

        public mutating func run() async throws {
            let result = try MailBridge.moveMessage(
                compoundId: messageId,
                toMailbox: to,
                dryRun: dryRun
            )
            try printJSON(result)
        }
    }

    public struct List: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List messages. Defaults to INBOX, all messages, limit 50."
        )

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @Option(name: .long, help: "Mailbox name (default: INBOX).")
        public var mailbox: String = "INBOX"

        @Flag(name: .long, help: "Only show unread messages.")
        public var unread: Bool = false

        @Option(name: .long, help: "Maximum number of messages to return.")
        public var limit: Int = 50

        public init() {}

        public mutating func run() async throws {
            let messages = try MailBridge.listMessages(
                account: account,
                mailbox: mailbox,
                unread: unread,
                limit: limit
            )
            try printJSON(messages)
        }
    }

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
            try printJSON(result)
        }
    }

    public struct Read: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "read",
            abstract: "Read a message by its compound id (from `mail list` output)."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        public var messageId: String

        public init() {}

        public mutating func run() async throws {
            let message = try MailBridge.readMessage(compoundId: messageId)
            try printJSON(message)
        }
    }
}
