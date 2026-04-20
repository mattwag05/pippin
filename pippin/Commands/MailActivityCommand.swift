import ArgumentParser
import Foundation

public extension MailCommand {
    struct Activity: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "activity",
            abstract: "Combined recent mail activity across multiple mailboxes (e.g. INBOX + Sent). Use this for scan workflows instead of N calls to mail list.",
            discussion: "Default scans INBOX and Sent with a 200-char body preview. Use --since to bound the scan window; --mailboxes to customize the set."
        )

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @Option(name: .long, help: "Comma-separated mailbox names (default: INBOX,Sent). Aliases like 'Trash'/'Junk'/'Sent'/'Drafts' are resolved per-provider.")
        public var mailboxes: String = "INBOX,Sent"

        @Option(name: .long, help: "Only include messages on or after this date: YYYY-MM-DD or ISO 8601.")
        public var since: String?

        @Option(name: .long, help: "Maximum number of messages to return (default: 50).")
        public var limit: Int = 50

        @Option(name: .long, help: "Plain-text body preview length in chars (default: 200; 0 to disable).")
        public var preview: Int = 200

        @OptionGroup public var output: OutputOptions

        public init() {}

        public mutating func validate() throws {
            guard limit >= 1 else {
                throw ValidationError("--limit must be 1 or greater.")
            }
            guard preview >= 0 else {
                throw ValidationError("--preview must be 0 or greater.")
            }
            if let since, parseCalendarDate(since) == nil {
                throw ValidationError("--since must be YYYY-MM-DD or ISO 8601 (e.g. 2026-04-13).")
            }
            guard !Self.parseMailboxList(mailboxes).isEmpty else {
                throw ValidationError("--mailboxes must contain at least one name (e.g. INBOX,Sent).")
            }
        }

        public mutating func run() async throws {
            let messages = try MailBridge.listActivity(
                account: account,
                mailboxes: Self.parseMailboxList(mailboxes),
                since: since.flatMap { parseCalendarDate($0) },
                limit: limit,
                preview: preview > 0 ? preview : nil
            )
            if output.isJSON {
                try printJSON(messages)
            } else if output.isAgent {
                try printAgentJSON(messages)
            } else {
                printMessageTable(messages)
            }
        }

        static func parseMailboxList(_ raw: String) -> [String] {
            raw.split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}
