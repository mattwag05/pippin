import Foundation

/// Persisted session state for the REPL.
/// Stored at ~/.config/pippin/session.json.
public struct SessionState: Codable, Sendable {
    /// Active mail account name (e.g. "iCloud", "Work").
    public var activeAccount: String?

    /// Active mailbox within the active account (e.g. "INBOX", "Sent").
    public var activeMailbox: String?

    /// Last message compound ID interacted with.
    public var lastMessageId: String?

    /// Last calendar event ID interacted with.
    public var lastEventId: String?

    /// Last reminder ID interacted with.
    public var lastReminderId: String?

    /// Last note ID interacted with.
    public var lastNoteId: String?

    /// Command history (most recent last). Capped at 100 entries.
    public var history: [String]

    /// Timestamp of last session activity.
    public var lastActive: Date

    public init() {
        history = []
        lastActive = Date()
    }
}

/// Manages loading, saving, and updating session state.
public final class SessionManager: @unchecked Sendable {
    public static let defaultPath: String = {
        let home = NSHomeDirectory()
        return "\(home)/.config/pippin/session.json"
    }()

    private let path: String
    private var state: SessionState
    private let lock = NSLock()

    public init(path: String? = nil) {
        self.path = path ?? SessionManager.defaultPath
        state = SessionManager.load(from: self.path) ?? SessionState()
    }

    // MARK: - Accessors

    public var activeAccount: String? {
        lock.withLock { state.activeAccount }
    }

    public var activeMailbox: String? {
        lock.withLock { state.activeMailbox }
    }

    public var lastMessageId: String? {
        lock.withLock { state.lastMessageId }
    }

    public var lastEventId: String? {
        lock.withLock { state.lastEventId }
    }

    public var lastReminderId: String? {
        lock.withLock { state.lastReminderId }
    }

    public var lastNoteId: String? {
        lock.withLock { state.lastNoteId }
    }

    public var history: [String] {
        lock.withLock { state.history }
    }

    public var currentState: SessionState {
        lock.withLock { state }
    }

    // MARK: - Mutators

    public func setActiveAccount(_ account: String?) {
        lock.withLock {
            state.activeAccount = account
            if account == nil { state.activeMailbox = nil }
        }
        save()
    }

    public func setActiveMailbox(_ mailbox: String?) {
        lock.withLock { state.activeMailbox = mailbox }
        save()
    }

    public func setLastMessageId(_ id: String?) {
        lock.withLock { state.lastMessageId = id }
        save()
    }

    public func setLastEventId(_ id: String?) {
        lock.withLock { state.lastEventId = id }
        save()
    }

    public func setLastReminderId(_ id: String?) {
        lock.withLock { state.lastReminderId = id }
        save()
    }

    public func setLastNoteId(_ id: String?) {
        lock.withLock { state.lastNoteId = id }
        save()
    }

    public func recordCommand(_ command: String) {
        lock.withLock {
            state.history.append(command)
            if state.history.count > 100 {
                state.history.removeFirst(state.history.count - 100)
            }
            state.lastActive = Date()
        }
        save()
    }

    public func clearContext() {
        lock.withLock {
            state.activeAccount = nil
            state.activeMailbox = nil
            state.lastMessageId = nil
            state.lastEventId = nil
            state.lastReminderId = nil
            state.lastNoteId = nil
        }
        save()
    }

    public func clearHistory() {
        lock.withLock { state.history = [] }
        save()
    }

    // MARK: - Persistence

    private func save() {
        let snapshot = lock.withLock { state }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Atomic write
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private static func load(from path: String) -> SessionState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionState.self, from: data)
    }
}
