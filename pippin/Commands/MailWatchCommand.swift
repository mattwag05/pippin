import ArgumentParser
import Foundation

private struct WatchEvent: Encodable {
    let event: String
    let message: MailMessage
}

public extension MailCommand {
    struct Watch: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "watch",
            abstract: "Poll for new mail and emit events as newline-delimited JSON.",
            discussion: "Emits one JSON object per line for each new message detected. Press Ctrl-C to stop."
        )

        @Option(name: .long, help: "Filter by account name.")
        public var account: String?

        @Option(name: .long, help: "Mailbox to watch (default: INBOX).")
        public var mailbox: String = "INBOX"

        @Option(name: .long, help: "Poll interval in seconds (default: 30).")
        public var interval: Int = 30

        @Option(name: .long, help: "Maximum messages to fetch per poll (default: 50).")
        public var limit: Int = 50

        public init() {}

        public mutating func validate() throws {
            guard interval >= 5 else {
                throw ValidationError("--interval must be at least 5 seconds.")
            }
            guard limit >= 1, limit <= 500 else {
                throw ValidationError("--limit must be between 1 and 500.")
            }
        }

        public mutating func run() async throws {
            var seen = Set<String>()

            let initial = try MailBridge.listMessages(
                account: account, mailbox: mailbox, unread: false, limit: limit
            )
            for msg in initial {
                seen.insert(msg.id)
            }

            let encoder = JSONEncoder()
            let sleepNs = UInt64(min(interval, 3600)) * 1_000_000_000

            fputs("Watching \(mailbox)\(account.map { " (\($0))" } ?? "") — polling every \(interval)s. Ctrl-C to stop.\n", stderr)

            while true {
                try await Task.sleep(nanoseconds: sleepNs)

                let messages: [MailMessage]
                do {
                    messages = try MailBridge.listMessages(
                        account: account, mailbox: mailbox, unread: false, limit: limit
                    )
                } catch {
                    fputs("poll error: \(error.localizedDescription)\n", stderr)
                    continue
                }

                for msg in messages where !seen.contains(msg.id) {
                    seen.insert(msg.id)
                    let watchEvent = WatchEvent(event: "new_message", message: msg)
                    do {
                        let data = try encoder.encode(watchEvent)
                        guard let line = String(data: data, encoding: .utf8) else {
                            fputs("Failed to convert message to UTF-8 string\n", stderr)
                            continue
                        }
                        print(line)
                        fflush(stdout)
                    } catch {
                        fputs("encode error: \(error.localizedDescription)\n", stderr)
                    }
                }
            }
        }
    }
}
