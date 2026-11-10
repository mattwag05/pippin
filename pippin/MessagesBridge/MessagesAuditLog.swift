import CryptoKit
import Foundation

public struct MessagesAuditEntry: Codable, Sendable {
    public let timestamp: String
    public let operation: String
    public let params: [String: String]
    public let resultCount: Int?
    public let recipient: String?
    public let bodyHash: String?
    public let sent: Bool?
    /// For sends: `attempt` (written before the send), then one of `success`,
    /// `failed`, `outcome_unknown`; or `refused` / `draft` when nothing was
    /// attempted. An `attempt` with no later line means pippin died mid-send.
    public let outcome: String?
    public let overrides: [String]?

    public init(
        timestamp: String,
        operation: String,
        params: [String: String] = [:],
        resultCount: Int? = nil,
        recipient: String? = nil,
        bodyHash: String? = nil,
        sent: Bool? = nil,
        outcome: String? = nil,
        overrides: [String]? = nil
    ) {
        self.timestamp = timestamp
        self.operation = operation
        self.params = params
        self.resultCount = resultCount
        self.recipient = recipient
        self.bodyHash = bodyHash
        self.sent = sent
        self.outcome = outcome
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, operation, params
        case resultCount = "result_count"
        case recipient
        case bodyHash = "body_hash"
        case sent
        case outcome
        case overrides
    }
}

/// Append-only JSONL writer for every messages read/send operation.
///
/// Default path: `~/.local/share/pippin/messages-audit.jsonl`. Each
/// invocation writes exactly one line. The body of outbound messages is
/// NEVER stored — only a SHA-256 hash. This is the paper trail that
/// powers the morning briefing's "Pippin sent N messages yesterday" line
/// and lets the user audit after an incident.
public enum MessagesAuditLog {
    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["PIPPIN_MESSAGES_AUDIT_PATH"] {
            return override
        }
        let home = NSHomeDirectory()
        return "\(home)/.local/share/pippin/messages-audit.jsonl"
    }

    public static func hash(body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Build an entry with a `now()` timestamp and append it, best effort.
    /// Returns false when the line could not be written. Reads use this; a send
    /// uses `recordOrThrow` for its attempt line so it can refuse to send blind.
    @discardableResult
    public static func record(
        operation: String,
        params: [String: String] = [:],
        resultCount: Int? = nil,
        recipient: String? = nil,
        bodyHash: String? = nil,
        sent: Bool? = nil,
        outcome: String? = nil,
        overrides: [String]? = nil,
        path: String? = nil
    ) -> Bool {
        (try? recordOrThrow(
            operation: operation, params: params, resultCount: resultCount, recipient: recipient,
            bodyHash: bodyHash, sent: sent, outcome: outcome, overrides: overrides, path: path
        )) != nil
    }

    public static func recordOrThrow(
        operation: String,
        params: [String: String] = [:],
        resultCount: Int? = nil,
        recipient: String? = nil,
        bodyHash: String? = nil,
        sent: Bool? = nil,
        outcome: String? = nil,
        overrides: [String]? = nil,
        path: String? = nil
    ) throws {
        try append(
            MessagesAuditEntry(
                timestamp: now(),
                operation: operation,
                params: params,
                resultCount: resultCount,
                recipient: recipient,
                bodyHash: bodyHash,
                sent: sent,
                outcome: outcome,
                overrides: overrides
            ),
            path: path
        )
    }

    public static func append(_ entry: MessagesAuditEntry, path: String? = nil) throws {
        let target = path ?? defaultPath()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Same writer as the action log: O_APPEND and 0600 (the log names
        // every recipient and search query).
        try AppendOnlyFile.append(encoder.encode(entry) + Data("\n".utf8), to: target)
    }

    public static func now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
