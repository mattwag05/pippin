import Foundation

public struct MessageParticipant: Codable, Sendable, Equatable {
    public let handle: String
    public let service: String
    public let displayName: String?

    public init(handle: String, service: String, displayName: String? = nil) {
        self.handle = handle
        self.service = service
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case handle
        case service
        case displayName = "display_name"
    }
}

public struct MessageConversation: Codable, Sendable, Equatable {
    public let id: String
    public let service: String
    public let displayName: String?
    public let participants: [MessageParticipant]
    public let isGroup: Bool
    public let lastMessageAt: String?
    public let lastMessagePreview: String?
    public let unreadCount: Int

    public init(
        id: String,
        service: String,
        displayName: String?,
        participants: [MessageParticipant],
        isGroup: Bool,
        lastMessageAt: String?,
        lastMessagePreview: String?,
        unreadCount: Int
    ) {
        self.id = id
        self.service = service
        self.displayName = displayName
        self.participants = participants
        self.isGroup = isGroup
        self.lastMessageAt = lastMessageAt
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case service
        case displayName = "display_name"
        case participants
        case isGroup = "is_group"
        case lastMessageAt = "last_message_at"
        case lastMessagePreview = "last_message_preview"
        case unreadCount = "unread_count"
    }
}

/// Attachment metadata on a message row (from `message_attachment_join` +
/// `attachment`). `filename` is a display name — the last path component when
/// the DB stores a full path.
public struct MessageAttachment: Codable, Sendable, Equatable {
    public let filename: String?
    public let mimeType: String?

    public init(filename: String?, mimeType: String?) {
        self.filename = filename
        self.mimeType = mimeType
    }

    private enum CodingKeys: String, CodingKey {
        case filename
        case mimeType = "mime_type"
    }
}

public struct MessageItem: Codable, Sendable, Equatable {
    public let id: String
    public let conversationId: String
    public let date: String
    public let text: String?
    public let fromHandle: String?
    public let fromDisplayName: String?
    public let isFromMe: Bool
    public let isRead: Bool
    public let service: String
    /// nil (key omitted in JSON) when the message has no attachments.
    public let attachments: [MessageAttachment]?

    public init(
        id: String,
        conversationId: String,
        date: String,
        text: String?,
        fromHandle: String?,
        fromDisplayName: String?,
        isFromMe: Bool,
        isRead: Bool,
        service: String,
        attachments: [MessageAttachment]? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.date = date
        self.text = text
        self.fromHandle = fromHandle
        self.fromDisplayName = fromDisplayName
        self.isFromMe = isFromMe
        self.isRead = isRead
        self.service = service
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case date
        case text
        case fromHandle = "from_handle"
        case fromDisplayName = "from_display_name"
        case isFromMe = "is_from_me"
        case isRead = "is_read"
        case service
        case attachments
    }
}

public struct MessagesSearchResult: Codable, Sendable {
    public let matches: [MessageItem]
    public let excludedCount: Int
    public let query: String
    /// True when the `attributedBody` decode-scan hit its recency cap, so older
    /// blob-only messages went unscanned. When true, a "no match" (or a partial
    /// match set) is NOT authoritative — there may be older matches outside the
    /// scanned window. (pippin-wve)
    public let scanTruncated: Bool
    /// The cap that bounded the `attributedBody` decode-scan (number of
    /// most-recent blob-only messages examined). Surfaced alongside
    /// `scanTruncated` so callers can report the scanned depth.
    public let scannedAttributedCap: Int

    public init(
        matches: [MessageItem],
        excludedCount: Int,
        query: String,
        scanTruncated: Bool,
        scannedAttributedCap: Int
    ) {
        self.matches = matches
        self.excludedCount = excludedCount
        self.query = query
        self.scanTruncated = scanTruncated
        self.scannedAttributedCap = scannedAttributedCap
    }

    private enum CodingKeys: String, CodingKey {
        case matches
        case excludedCount = "excluded_count"
        case query
        case scanTruncated = "scan_truncated"
        case scannedAttributedCap = "scanned_attributed_cap"
    }
}

public struct MessagesShowResult: Codable, Sendable {
    public let conversation: MessageConversation
    public let messages: [MessageItem]
    public let truncated: Bool

    public init(conversation: MessageConversation, messages: [MessageItem], truncated: Bool) {
        self.conversation = conversation
        self.messages = messages
        self.truncated = truncated
    }
}

public struct MessagesExcludeResult: Codable, Sendable {
    public let action: String
    public let threads: [String]

    public init(action: String, threads: [String]) {
        self.action = action
        self.threads = threads
    }
}

public struct MessagesSendResult: Codable, Sendable {
    public let recipient: String
    public let delivered: Bool
    public let mode: String
    public let detail: String?
    public let bodyHash: String

    public init(
        recipient: String,
        delivered: Bool,
        mode: String,
        detail: String? = nil,
        bodyHash: String
    ) {
        self.recipient = recipient
        self.delivered = delivered
        self.mode = mode
        self.detail = detail
        self.bodyHash = bodyHash
    }

    private enum CodingKeys: String, CodingKey {
        case recipient
        case delivered
        case mode
        case detail
        case bodyHash = "body_hash"
    }
}
