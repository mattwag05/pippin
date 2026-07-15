import Foundation

public enum NotesBridgeError: LocalizedError, Sendable {
    case scriptFailed(String)
    /// The JXA scripts throw the sentinel `NOTESBRIDGE_ERR_NOT_FOUND: <id>` for
    /// a missing note; `NotesBridge.mapScriptFailure` detects it and produces
    /// this typed case so agents get `error.code = "note_not_found"` (exit 3)
    /// instead of a generic `script_failed` (exit 5). Mirrors
    /// `ContactsBridgeError.contactNotFound`.
    case noteNotFound(String)
    case timeout
    case decodingFailed(String)
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case let .scriptFailed(msg):
            return "Notes automation script failed: \(msg.prefix(200))"
        case let .noteNotFound(id):
            return id.isEmpty ? "Note not found." : "Note not found: \(id)"
        case .timeout: return "Notes automation timed out. Ensure Notes.app is running."
        case .decodingFailed: return "Failed to decode Notes response"
        case .accessDenied: return "Notes automation is not authorized. Grant Automation control of Notes and retry."
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

extension NotesBridgeError: RemediableError {
    public var remediation: Remediation? {
        switch self {
        case .accessDenied: return .automationAccess(app: "Notes", trigger: "pippin notes folders")
        default: return nil
        }
    }
}

public struct NoteInfo: Codable, Sendable {
    public let id: String
    public let title: String
    /// HTML body. Only `notes show` fetches it — list/search skip the
    /// expensive per-note `.body()` Apple Event and leave this nil, so it is
    /// omitted from their serialized output (use `notes show <id>` for HTML).
    public let body: String?
    public let plainText: String
    public let folder: String
    public let folderId: String
    public let account: String?
    public let creationDate: String
    public let modificationDate: String

    /// Serialized keys use `createdAt`/`modifiedAt` (envelope v2 field rename);
    /// the Swift property names stay `creationDate`/`modificationDate` because
    /// external consumers (`NoteDigestInfo`, `actions extract`) read them.
    private enum CodingKeys: String, CodingKey {
        case id, title, body, plainText, folder, folderId, account
        case creationDate = "createdAt"
        case modificationDate = "modifiedAt"
    }

    public init(
        id: String,
        title: String,
        body: String? = nil,
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
