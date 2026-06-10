import Foundation

// MARK: - MailBridgeError

public enum MailBridgeError: LocalizedError, Sendable {
    case scriptFailed(String)
    case timeout
    case decodingFailed(String)
    case invalidMessageId(String)
    case invalidMailbox(String)
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case let .scriptFailed(msg): return "Mail automation script failed: \(msg.prefix(200))"
        case .timeout: return "Mail automation timed out. Try narrowing with --account, --mailbox, or --after."
        case .decodingFailed: return "Failed to decode Mail response"
        case let .invalidMessageId(id): return "Invalid message id: \(id)"
        case let .invalidMailbox(name): return "Invalid mailbox name: \(name)"
        case .accessDenied: return "Mail automation is not authorized. Grant Automation control of Mail and retry."
        }
    }

    /// Raw technical detail for debugging — do not write to stdout
    public var debugDetail: String? {
        switch self {
        case let .scriptFailed(msg): return msg
        case let .decodingFailed(msg): return msg
        default: return nil
        }
    }
}

extension MailBridgeError: RemediableError {
    public var remediation: Remediation? {
        switch self {
        case .accessDenied: return .automationAccess(app: "Mail", trigger: "pippin mail list")
        default: return nil
        }
    }
}

// MARK: - MailMessage

public struct MailMessage: Codable, Sendable {
    public let id: String // compound: "account||mailbox||messageId"
    public let account: String
    public let mailbox: String
    public let subject: String
    public let from: String
    public let to: [String]
    public let date: String // ISO 8601
    public let read: Bool // snapshot at fetch/cache time, NOT live — use `mail list`/`search` for live read state
    public let body: String? // only populated by `show` command
    public let size: Int? // bytes; available in list/search
    public let hasAttachment: Bool? // quick flag; available in list/search
    public let bodyPreview: String? // populated by `list --preview N` for agent scan workflows
    public let htmlBody: String? // only populated by `show`
    public let headers: [String: String]? // only populated by `show`
    public let attachments: [Attachment]? // only populated by `show`
    public let fromContact: String? // Apple Contacts display name for the sender, when resolved

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
        bodyPreview: String? = nil,
        htmlBody: String? = nil,
        headers: [String: String]? = nil,
        attachments: [Attachment]? = nil,
        fromContact: String? = nil
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
        self.bodyPreview = bodyPreview
        self.htmlBody = htmlBody
        self.headers = headers
        self.attachments = attachments
        self.fromContact = fromContact
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
        try container.encodeIfPresent(bodyPreview, forKey: .bodyPreview)
        try container.encodeIfPresent(htmlBody, forKey: .htmlBody)
        try container.encodeIfPresent(headers, forKey: .headers)
        try container.encodeIfPresent(attachments, forKey: .attachments)
        try container.encodeIfPresent(fromContact, forKey: .fromContact)
    }
}

public extension MailMessage {
    /// Return a copy with `bodyPreview` replaced, all other fields preserved.
    /// Used by `MailBridge.assemblePreviews` to attach a derived preview to a
    /// live metadata row without disturbing its read/unread or other fields.
    func withBodyPreview(_ preview: String?) -> MailMessage {
        MailMessage(
            id: id, account: account, mailbox: mailbox, subject: subject,
            from: from, to: to, date: date, read: read, body: body,
            size: size, hasAttachment: hasAttachment, bodyPreview: preview,
            htmlBody: htmlBody, headers: headers, attachments: attachments,
            fromContact: fromContact
        )
    }

    /// Return a copy with `fromContact` set — used by the command layer to tie the
    /// sender to an Apple Contacts name after the (JXA) bridge fetch returns.
    func withFromContact(_ contact: String?) -> MailMessage {
        MailMessage(
            id: id, account: account, mailbox: mailbox, subject: subject,
            from: from, to: to, date: date, read: read, body: body,
            size: size, hasAttachment: hasAttachment, bodyPreview: bodyPreview,
            htmlBody: htmlBody, headers: headers, attachments: attachments,
            fromContact: contact
        )
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
    public let savedPath: String? // nil unless --save-dir was used

    public init(name: String, mimeType: String, size: Int, savedPath: String? = nil) {
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.savedPath = savedPath
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(size, forKey: .size)
        try container.encodeIfPresent(savedPath, forKey: .savedPath)
    }
}

public struct Mailbox: Codable, Sendable {
    public let name: String
    public let account: String
    public let messageCount: Int
    public let unreadCount: Int
}
