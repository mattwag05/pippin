import ArgumentParser
import Foundation

struct MailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Interact with Apple Mail.",
        subcommands: [Accounts.self, Search.self, List.self, Read.self, Mark.self]
    )

    struct Accounts: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "accounts",
            abstract: "List configured Mail accounts."
        )

        mutating func run() async throws {
            let accounts = try MailBridge.listAccounts()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(accounts)
            print(String(data: data, encoding: .utf8)!)
        }
    }

    struct Search: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search messages by subject, sender, or body."
        )

        @Argument(help: "Search query (case-insensitive, matches subject/sender/body).")
        var query: String

        @Option(name: .long, help: "Filter by account name.")
        var account: String?

        @Option(name: .long, help: "Maximum number of results to return (default: 10).")
        var limit: Int = 10

        mutating func run() async throws {
            let messages = try MailBridge.searchMessages(
                query: query,
                account: account,
                limit: limit
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(messages)
            print(String(data: data, encoding: .utf8)!)
        }
    }

    struct Mark: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mark",
            abstract: "Mark a message as read or unread."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        var messageId: String

        @Flag(name: .long, help: "Mark as read.")
        var read: Bool = false

        @Flag(name: .long, help: "Mark as unread.")
        var unread: Bool = false

        @Flag(name: .long, help: "Print what would happen without making changes.")
        var dryRun: Bool = false

        mutating func validate() throws {
            guard read != unread else {
                throw ValidationError("Specify exactly one of --read or --unread.")
            }
        }

        mutating func run() async throws {
            let result = try MailBridge.markMessage(
                compoundId: messageId,
                read: read,
                dryRun: dryRun
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List messages. Defaults to INBOX, all messages, limit 50."
        )

        @Option(name: .long, help: "Filter by account name.")
        var account: String?

        @Option(name: .long, help: "Mailbox name (default: INBOX).")
        var mailbox: String = "INBOX"

        @Flag(name: .long, help: "Only show unread messages.")
        var unread: Bool = false

        @Option(name: .long, help: "Maximum number of messages to return.")
        var limit: Int = 50

        mutating func run() async throws {
            let messages = try MailBridge.listMessages(
                account: account,
                mailbox: mailbox,
                unread: unread,
                limit: limit
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(messages)
            print(String(data: data, encoding: .utf8)!)
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "read",
            abstract: "Read a message by its compound id (from `mail list` output)."
        )

        @Argument(help: "Message id from `pippin mail list` output.")
        var messageId: String

        mutating func run() async throws {
            let message = try MailBridge.readMessage(compoundId: messageId)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(message)
            print(String(data: data, encoding: .utf8)!)
        }
    }
}
