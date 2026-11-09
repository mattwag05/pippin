import Foundation
import GRDB

/// On-disk cache of the contact-resolution index (`ContactIndex`), keyed by the
/// address book's `CNContactStore.currentHistoryToken` so it self-invalidates
/// on any Contacts change.
///
/// Enumerating the whole `CNContactStore` on every command is the expensive
/// part of sender enrichment; the resulting handle→name maps are tiny and only
/// change when the address book does. The cache stores the **final** maps
/// (post-first-write-wins, including the last-10-digit phone fallback keys), so
/// a hit rebuilds the index by direct dictionary population with semantics
/// identical to a live enumeration. All operations are best-effort: any failure
/// reads as a miss and callers fall back to live enumeration, matching the
/// bridge's silent-when-unauthorized contract.
public final class ContactIndexCache: Sendable {
    /// Process-wide default cache. `nil` if the store can't be opened (e.g. a
    /// read-only home or corrupt file) — callers then enumerate live.
    public static let shared: ContactIndexCache? = try? ContactIndexCache()

    public static func defaultStorePath() -> String {
        "\(NSHomeDirectory())/.config/pippin/contact-index.db"
    }

    /// Bump to discard caches written by an incompatible older layout.
    private static let schemaVersion = 2

    private let dbQueue: DatabaseQueue

    public init(dbPath: String? = nil) throws {
        dbQueue = try openCacheQueue(path: dbPath ?? Self.defaultStorePath())
        try migrate()
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value BLOB NOT NULL
            )
            """)
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS mappings (
                kind TEXT NOT NULL,
                key  TEXT NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (kind, key)
            )
            """)
        }
    }

    // MARK: - Read / write

    /// Return the cached index when the stored history token equals `token`
    /// (address book unchanged since the cached enumeration), or `nil` on any
    /// miss, mismatch, version skew, or error — never throws, never crashes.
    public func load(matching token: Data) -> ContactIndex? {
        let maps = try? dbQueue.read { db -> (byPhone: [String: String], byEmail: [String: String])? in
            guard let version = try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'schema_version'"),
                  version == Self.schemaVersion,
                  let stored = try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'history_token'"),
                  stored == token,
                  // A resumable partial scan must never read as a finished index.
                  try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'resume_offset'") == nil
            else { return nil }
            var byPhone: [String: String] = [:]
            var byEmail: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT kind, key, name FROM mappings") {
                let kind: String = row["kind"]
                let key: String = row["key"]
                let name: String = row["name"]
                switch kind {
                case "phone": byPhone[key] = name
                case "email": byEmail[key] = name
                default: break
                }
            }
            return (byPhone, byEmail)
        }
        guard let maps = maps ?? nil else { return nil } // flatten try?'s outer optional
        return ContactIndex(byPhone: maps.byPhone, byEmail: maps.byEmail)
    }

    /// The partial index and how many contacts it covers, if a scan under this
    /// same `token` was cut off. A different token means the address book
    /// changed mid-scan, so the partial work is not returned and gets replaced.
    public func loadPartial(matching token: Data) -> (index: ContactIndex, offset: Int)? {
        let found = try? dbQueue.read { db -> (byPhone: [String: String], byEmail: [String: String], offset: Int)? in
            guard let version = try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'schema_version'"),
                  version == Self.schemaVersion,
                  let stored = try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'history_token'"),
                  stored == token,
                  let offset = try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'resume_offset'")
            else { return nil }
            var byPhone: [String: String] = [:]
            var byEmail: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT kind, key, name FROM mappings") {
                let key: String = row["key"]
                let name: String = row["name"]
                if (row["kind"] as String) == "phone" { byPhone[key] = name } else { byEmail[key] = name }
            }
            return (byPhone, byEmail, offset)
        }
        guard let found = found ?? nil else { return nil }
        return (ContactIndex(byPhone: found.byPhone, byEmail: found.byEmail), found.offset)
    }

    /// Replace the cache with `index`'s final maps under `token`. A non-nil
    /// `resumeOffset` marks it incomplete: readable only through `loadPartial`.
    /// Best-effort: failures never propagate (the caller has its live index).
    public func store(_ index: ContactIndex, token: Data, resumeOffset: Int? = nil) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM mappings")
            for (key, name) in index.byPhone {
                try db.execute(
                    sql: "INSERT INTO mappings (kind, key, name) VALUES ('phone', ?, ?)",
                    arguments: [key, name]
                )
            }
            for (key, name) in index.byEmail {
                try db.execute(
                    sql: "INSERT INTO mappings (kind, key, name) VALUES ('email', ?, ?)",
                    arguments: [key, name]
                )
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?), ('history_token', ?)",
                arguments: [Self.schemaVersion, token]
            )
            try db.execute(sql: "DELETE FROM meta WHERE key = 'resume_offset'")
            if let resumeOffset {
                try db.execute(
                    sql: "INSERT INTO meta (key, value) VALUES ('resume_offset', ?)",
                    arguments: [resumeOffset]
                )
            }
        }
    }
}
