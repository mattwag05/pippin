import ArgumentParser
import Foundation

public extension MailCommand {
    /// Inspect and manage the local mail body cache (`~/.config/pippin/mail-cache.db`).
    /// The cache holds fully-fetched message bodies keyed by compound id so
    /// repeated `mail show` / `mail index` runs skip the expensive `msg.content()`
    /// IMAP download. Read/unread state is never cached — `mail list`/`search`
    /// stay live.
    struct Cache: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "cache",
            abstract: "Inspect and manage the local mail body cache.",
            subcommands: [Stats.self, Clear.self, Warm.self]
        )

        public init() {}

        struct ClearResult: Codable { let deleted: Int }
        struct WarmResult: Codable {
            let warmed: Int
            let failed: Int
        }

        // MARK: - stats

        struct Stats: AgentCommand {
            public static let configuration = CommandConfiguration(
                commandName: "stats",
                abstract: "Show cached message count and age range."
            )

            @OptionGroup public var output: OutputOptions

            public init() {}

            public mutating func execute() async throws -> AgentResult {
                let stats = MailBodyCache.shared?.stats() ?? MailCacheStats(count: 0, oldest: nil, newest: nil)
                return AgentResult(stats)
            }
        }

        // MARK: - clear

        struct Clear: AgentCommand {
            public static let configuration = CommandConfiguration(
                commandName: "clear",
                abstract: "Delete all cached message bodies (or only those older than --older-than-days)."
            )

            @Option(name: .customLong("older-than-days"), help: "Only delete entries cached more than N days ago.")
            public var olderThanDays: Int?

            @OptionGroup public var output: OutputOptions

            public init() {}

            public mutating func execute() async throws -> AgentResult {
                let deleted: Int
                if let days = olderThanDays {
                    let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
                    deleted = MailBodyCache.shared?.prune(olderThan: cutoff) ?? 0
                } else {
                    deleted = MailBodyCache.shared?.clear() ?? 0
                }
                return AgentResult(ClearResult(deleted: deleted))
            }
        }

        // MARK: - warm

        struct Warm: AgentCommand {
            public static let configuration = CommandConfiguration(
                commandName: "warm",
                abstract: "Pre-fetch recent message bodies into the cache so later reads are instant."
            )

            @Option(name: .long, help: "Limit to a single account (default: all).")
            public var account: String?

            @Option(name: .long, help: "Mailbox to warm (default: INBOX).")
            public var mailbox: String = "INBOX"

            @Option(name: .long, help: "Maximum messages to warm (default: 20).")
            public var limit: Int = 20

            @OptionGroup public var output: OutputOptions

            public init() {}

            public mutating func validate() throws {
                guard limit > 0 else { throw ValidationError("--limit must be positive.") }
            }

            public mutating func execute() async throws -> AgentResult {
                let account = self.account
                let mailbox = self.mailbox
                let limit = self.limit
                // Enumerate metadata (fast), then read each body through the
                // cache so the expensive msg.content() fetch happens once here.
                let (warmed, failed) = try await detachBlocking { () -> (Int, Int) in
                    let outcome = try MailBridge.listMessages(account: account, mailbox: mailbox, limit: limit)
                    var warmed = 0
                    var failed = 0
                    for message in outcome.messages {
                        do {
                            _ = try MailBridge.readMessage(row: message)
                            warmed += 1
                        } catch {
                            failed += 1
                        }
                    }
                    return (warmed, failed)
                }
                return AgentResult(WarmResult(warmed: warmed, failed: failed))
            }
        }
    }
}
