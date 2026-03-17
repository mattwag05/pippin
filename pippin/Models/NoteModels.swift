import Foundation

public enum NotesBridgeError: LocalizedError, Sendable {
    case scriptFailed(String)
    case timeout
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .scriptFailed(msg):
            if msg.contains("NOTESBRIDGE_ERR_NOT_FOUND") { return "Note not found." }
            return "Notes automation script failed: \(msg.prefix(200))"
        case .timeout: return "Notes automation timed out. Ensure Notes.app is running."
        case .decodingFailed: return "Failed to decode Notes response"
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

public struct NoteInfo: Codable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let plainText: String
    public let folder: String
    public let folderId: String
    public let account: String?
    public let creationDate: String
    public let modificationDate: String

    public init(
        id: String,
        title: String,
        body: String,
        plainText: String,
        folder: String,
        folderId: String,
        account: String? = nil,
        creationDate: String,
        modificationDate: String
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.plainText = plainText
        self.folder = folder
        self.folderId = folderId
        self.account = account
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }
}

public struct NoteFolder: Codable, Sendable {
    public let id: String
    public let name: String
    public let account: String?
    public let noteCount: Int

    public init(id: String, name: String, account: String? = nil, noteCount: Int) {
        self.id = id
        self.name = name
        self.account = account
        self.noteCount = noteCount
    }
}

public struct NoteActionResult: Codable, Sendable {
    public let success: Bool
    public let action: String
    public let details: [String: String]

    public init(success: Bool, action: String, details: [String: String]) {
        self.success = success
        self.action = action
        self.details = details
    }
}
