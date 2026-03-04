import Foundation

public struct MailMessage: Codable, Sendable {
    public let id: String       // compound: "account||mailbox||messageId"
    public let account: String
    public let mailbox: String
    public let subject: String
    public let from: String
    public let to: [String]
    public let date: String     // ISO 8601
    public let read: Bool
    public let body: String?    // only populated by `read` command

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(account, forKey: .account)
        try container.encode(mailbox, forKey: .mailbox)
        try container.encode(subject, forKey: .subject)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
        try container.encode(date, forKey: .date)
        try container.encode(read, forKey: .read)
        try container.encode(body, forKey: .body)   // encodes nil as JSON null
    }
}

public struct MailAccount: Codable, Sendable {
    public let name: String
    public let email: String
}

public struct MailActionResult: Codable, Sendable {
    public let success: Bool
    public let action: String
    public let details: [String: String]
}
