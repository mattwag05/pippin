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
/// message's *body* is immutable, but a compound id
/// (`account||mailbox||numericId`) can later name a DIFFERENT message, so
/// every read is checked against the message's current date (pippin-pvak).
/// Mutable metadata (read/unread, flags) is intentionally **not** served
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
        dbQueue = try openCacheQueue(path: dbPath ?? Self.defaultStorePath())
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

    /// Return the cached message for `compoundId` only if it is still the same
    /// message: its `date` must be the same instant as `expectedDate` (the date
    /// the live list row or the Envelope Index reports for that id). `nil` on a
    /// miss, a decode failure, or an identity mismatch; a mismatched row is
    /// evicted.
    ///
    /// The identity check exists because a compound id is NOT permanent
    /// (pippin-pvak): Mail can hand a message's ROWID to a different message
    /// (an index rebuild renumbers them), and an unchecked hit then serves the
    /// old message's body, headers and anomalies under the new message's id.
    public func get(compoundId: String, expectedDate: String) -> MailMessage? {
        getMany(expectedDates: [compoundId: expectedDate])[compoundId]
    }

    /// Batch form of `get(compoundId:expectedDate:)`: one read for every id in
    /// `expectedDates` (the `mail list --preview` partition step). Misses,
    /// corrupt rows and identity mismatches are absent from the result;
    /// mismatched rows are evicted so the write-through of the fresh fetch
    /// replaces them.
    public func getMany(expectedDates: [String: String]) -> [String: MailMessage] {
        guard !expectedDates.isEmpty,
              let records = try? dbQueue.read({ db in
                  try MailBodyRecord.filter(keys: Array(expectedDates.keys)).fetchAll(db)
              })
        else { return [:] }
        let decoder = JSONDecoder()
        var out: [String: MailMessage] = [:]
        var stale: [String] = []
        for record in records {
            guard let message = try? decoder.decode(MailMessage.self, from: record.messageData),
                  let expected = expectedDates[record.compoundId] else { continue }
            if Self.sameInstant(message.date, expected) {
                out[record.compoundId] = message
            } else {
                stale.append(record.compoundId)
            }
        }
        if !stale.isEmpty {
            _ = try? dbQueue.write { db in try MailBodyRecord.deleteAll(db, keys: stale) }
        }
        return out
    }

    /// ISO 8601 instants compare equal with or without fractional seconds
    /// (`…:20Z` == `…:20.000Z`); unparseable strings fall back to exact match.
    static func sameInstant(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let a = parseInstant(lhs), let b = parseInstant(rhs) else { return false }
        return a == b
    }

    private static func parseInstant(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
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
