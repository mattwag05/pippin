import Foundation

/// Persisted session state for the REPL.
/// Stored at ~/.config/pippin/session.json.
public struct SessionState: Codable, Sendable {
    /// Active mail account name (e.g. "iCloud", "Work").
    public var activeAccount: String?

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
            persistLocked()
        }
    }

    public func recordCommand(_ command: String) {
        lock.withLock {
            state.history.append(command)
            if state.history.count > 100 {
                state.history.removeFirst(state.history.count - 100)
            }
            state.lastActive = Date()
            persistLocked()
        }
    }

    // MARK: - Persistence

    /// Encode the current state and write it atomically. **The caller must hold
    /// `lock`.** Keeping the snapshot+write inside the same lock as the mutation
    /// makes "mutate then persist" a single ordered operation: concurrent
    /// mutators can no longer let an older snapshot's disk write land last and
    /// revert a sibling field on disk (a lost update if the process exits during
    /// concurrent session activity). The file is tiny, so holding the lock
    /// across the atomic write is negligible.
    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }

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
