import Foundation

public struct MailMessage: Codable, Sendable {
    public let id: String // compound: "account||mailbox||messageId"
    public let account: String
    public let mailbox: String
    public let subject: String
    public let from: String
    public let to: [String]
    public let date: String // ISO 8601
    public let read: Bool
    public let body: String? // only populated by `show` command
    public let size: Int? // bytes; available in list/search
    public let hasAttachment: Bool? // quick flag; available in list/search
    public let htmlBody: String? // only populated by `show`
    public let headers: [String: String]? // only populated by `show`
    public let attachments: [Attachment]? // only populated by `show`

    public init(
        id: String,
        account: String,
        mailbox: String,
        subject: String,
        from: String,
        to: [String],
        date: String,
        read: Bool,
        body: String? = nil,
        size: Int? = nil,
        hasAttachment: Bool? = nil,
        htmlBody: String? = nil,
        headers: [String: String]? = nil,
        attachments: [Attachment]? = nil
    ) {
        self.id = id
        self.account = account
        self.mailbox = mailbox
        self.subject = subject
        self.from = from
        self.to = to
        self.date = date
        self.read = read
        self.body = body
        self.size = size
        self.hasAttachment = hasAttachment
        self.htmlBody = htmlBody
        self.headers = headers
        self.attachments = attachments
    }

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
        try container.encode(body, forKey: .body) // encodes nil as JSON null
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(hasAttachment, forKey: .hasAttachment)
        try container.encodeIfPresent(htmlBody, forKey: .htmlBody)
        try container.encodeIfPresent(headers, forKey: .headers)
        try container.encodeIfPresent(attachments, forKey: .attachments)
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

public struct Attachment: Codable, Sendable {
    public let name: String
    public let mimeType: String
    public let size: Int
}

public struct Mailbox: Codable, Sendable {
    public let name: String
    public let account: String
    public let messageCount: Int
    public let unreadCount: Int
}
