import Foundation
import GRDB

/// On-disk record for a cached message body. The message is stored as a JSON
/// `Data` BLOB so get/put move bytes straight in and out of the column with no
/// String transcoding.
public struct MailBodyRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "message_bodies"

    public let compoundId: String
    public let messageData: Data
    public let cachedAt: String

    enum CodingKeys: String, CodingKey {
        case compoundId = "compound_id"
        case messageData = "message_data"
        case cachedAt = "cached_at"
    }
}

/// Snapshot of cache contents for `mail cache stats`.
public struct MailCacheStats: Codable, Sendable {
    public let count: Int
    public let oldest: String?
    public let newest: String?

    enum CodingKeys: String, CodingKey {
        case count, oldest, newest
    }
}

/// Local cache of fully-fetched mail message bodies, keyed by compound id.
///
/// The expensive part of reading a message is `msg.content()` — a per-message
/// IMAP body download issued through JXA (see `docs/gotchas/jxa.md`). A
/// message's *body* is immutable for a given compound id
/// (`account||mailbox||numericId`), so caching the fetched `MailMessage` is
/// safe. Mutable metadata (read/unread, flags) is intentionally **not** served
/// from here — `mail list`/`search` always enumerate it live; only `mail show`
/// and `mail index` (which need the body anyway) read through this cache, and
/// `mail show` documents that its read flag reflects cache time.
public final class MailBodyCache: Sendable {
    /// Process-wide default cache. `nil` if the store can't be opened (e.g. a
    /// read-only home) — callers then transparently fall back to live fetches.
    public static let shared: MailBodyCache? = try? MailBodyCache()

    public static func defaultStorePath() -> String {
        "\(NSHomeDirectory())/.config/pippin/mail-cache.db"
    }

    private let dbQueue: DatabaseQueue

    public init(dbPath: String? = nil) throws {
        let path = dbPath ?? Self.defaultStorePath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: path)
        try migrate()
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS message_bodies (
                compound_id  TEXT PRIMARY KEY,
                message_data BLOB NOT NULL,
                cached_at    TEXT NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_mail_cache_cached_at ON message_bodies(cached_at)
            """)
        }
    }

    // MARK: - Read / write

    /// Return the cached message for `compoundId`, or `nil` on miss or decode
    /// failure (a corrupt row is treated as a miss, never a crash).
    public func get(compoundId: String) -> MailMessage? {
        guard let rec = try? dbQueue.read({ db in try MailBodyRecord.fetchOne(db, key: compoundId) }),
              let message = try? JSONDecoder().decode(MailMessage.self, from: rec.messageData)
        else { return nil }
        return message
    }

    /// Write-through store. Best-effort: cache failures never propagate to the
    /// caller (a read that can't be cached still returns its live result).
    public func put(_ message: MailMessage, at date: Date = Date()) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        let stamp = ISO8601DateFormatter().string(from: date)
        try? dbQueue.write { db in
            try MailBodyRecord(compoundId: message.id, messageData: data, cachedAt: stamp).save(db)
        }
    }

    // MARK: - Maintenance

    public func count() -> Int {
        (try? dbQueue.read { db in try MailBodyRecord.fetchCount(db) }) ?? 0
    }

    public func stats() -> MailCacheStats {
        let row = try? dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT COUNT(*) AS c, MIN(cached_at) AS lo, MAX(cached_at) AS hi FROM message_bodies")
        }
        guard let row else { return MailCacheStats(count: 0, oldest: nil, newest: nil) }
        return MailCacheStats(count: row["c"] ?? 0, oldest: row["lo"], newest: row["hi"])
    }

    /// Delete all rows. Returns the number deleted.
    @discardableResult
    public func clear() -> Int {
        (try? dbQueue.write { db in try MailBodyRecord.deleteAll(db) }) ?? 0
    }

    /// Delete rows cached before `cutoff`. Returns the number deleted.
    @discardableResult
    public func prune(olderThan cutoff: Date) -> Int {
        let stamp = ISO8601DateFormatter().string(from: cutoff)
        return (try? dbQueue.write { db in
            try MailBodyRecord
                .filter(sql: "cached_at < ?", arguments: [stamp])
                .deleteAll(db)
        }) ?? 0
    }
}
