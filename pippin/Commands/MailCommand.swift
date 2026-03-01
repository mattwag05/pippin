import ArgumentParser
import Foundation

struct MailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Interact with Apple Mail.",
        subcommands: [List.self, Read.self]
    )

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
