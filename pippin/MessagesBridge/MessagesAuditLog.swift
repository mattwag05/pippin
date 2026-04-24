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
    public let overrides: [String]?

    public init(
        timestamp: String,
        operation: String,
        params: [String: String] = [:],
        resultCount: Int? = nil,
        recipient: String? = nil,
        bodyHash: String? = nil,
        sent: Bool? = nil,
        overrides: [String]? = nil
    ) {
        self.timestamp = timestamp
        self.operation = operation
        self.params = params
        self.resultCount = resultCount
        self.recipient = recipient
        self.bodyHash = bodyHash
        self.sent = sent
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, operation, params
        case resultCount = "result_count"
        case recipient
        case bodyHash = "body_hash"
        case sent
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
        let home = NSHomeDirectory()
        return "\(home)/.local/share/pippin/messages-audit.jsonl"
    }

    public static func hash(body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func append(_ entry: MessagesAuditEntry, path: String? = nil) throws {
        let target = path ?? defaultPath()
        let dir = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entry) + Data("\n".utf8)
        let url = URL(fileURLWithPath: target)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    public static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
