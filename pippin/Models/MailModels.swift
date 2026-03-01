import Foundation

struct MailMessage: Codable {
    let id: String       // compound: "account||mailbox||messageId"
    let account: String
    let mailbox: String
    let subject: String
    let from: String
    let to: [String]
    let date: String     // ISO 8601
    let read: Bool
    let body: String?    // only populated by `read` command

    func encode(to encoder: Encoder) throws {
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
