import Foundation
import GRDB

public struct CachedTranscript: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "transcripts"

    public let memoId: String
    public let transcript: String
    public let transcribedAt: String
    public let provider: String

    public init(memoId: String, transcript: String, provider: String) {
        self.memoId = memoId
        self.transcript = transcript
        self.provider = provider
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        transcribedAt = formatter.string(from: Date())
    }

    enum CodingKeys: String, CodingKey {
        case memoId = "memo_id"
        case transcript
        case transcribedAt = "transcribed_at"
        case provider
    }
}

public final class TranscriptCache: Sendable {
    public static func defaultCachePath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.config/pippin/transcripts.db"
    }

    private let dbQueue: DatabaseQueue

    public init(dbPath: String? = nil) throws {
        let path = dbPath ?? TranscriptCache.defaultCachePath()
        // Ensure directory exists
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    // MARK: - Migration

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS transcripts (
                memo_id TEXT PRIMARY KEY,
                transcript TEXT NOT NULL,
                transcribed_at TEXT NOT NULL,
                provider TEXT NOT NULL
            )
            """)
        }
    }

    // MARK: - Public API

    /// Return cached transcript for memo, or nil if not cached.
    public func get(memoId: String) throws -> CachedTranscript? {
        try dbQueue.read { db in
            try CachedTranscript.fetchOne(db, sql: "SELECT * FROM transcripts WHERE memo_id = ?", arguments: [memoId])
        }
    }

    /// Store or update a transcript.
    public func set(memoId: String, transcript: String, provider: String) throws {
        let entry = CachedTranscript(memoId: memoId, transcript: transcript, provider: provider)
        try dbQueue.write { db in
            try entry.save(db)
        }
    }

    /// Remove a cached transcript.
    public func delete(memoId: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM transcripts WHERE memo_id = ?", arguments: [memoId])
        }
    }
}
