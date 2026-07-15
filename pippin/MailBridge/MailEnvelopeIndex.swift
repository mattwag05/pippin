import Foundation
import GRDB

// MARK: - Errors

/// Typed failures for the Envelope Index fast path. Every one of these means
/// "fall back to JXA" at the MailBridge hook — none are surfaced to users
/// (the fast path is a silent accelerator, per pippin-60x).
enum MailEnvelopeIndexError: LocalizedError {
    case databaseNotFound(String)
    case unsupportedVersion(Int)
    /// macOS TCC (Full Disk Access) or another OS-level permission blocked the
    /// snapshot copy or the read. Raw message attached for `pippin doctor`.
    case accessDenied(String)
    /// The account name→UUID map is empty and couldn't be refreshed.
    case accountsUnavailable(String)
    /// The requested mailbox name matched no mailbox URL across the targeted
    /// accounts (e.g. localized mailbox names) — JXA's special-mailbox
    /// accessors may still resolve it, so fall back rather than return [].
    case mailboxUnresolved(String)
    /// `--account` names an account absent from the UUID map.
    case accountUnknown(String)

    var errorDescription: String? {
        switch self {
        case let .databaseNotFound(path):
            return "Envelope Index not found at: \(path)"
        case let .unsupportedVersion(version):
            return "Unsupported Envelope Index schema version: \(version). Known: \(MailEnvelopeIndex.knownVersions)"
        case let .accessDenied(detail):
            return "Envelope Index access denied (\(detail))"
        case let .accountsUnavailable(detail):
            return "Mail account map unavailable: \(detail)"
        case let .mailboxUnresolved(name):
            return "Mailbox '\(name)' not found in Envelope Index"
        case let .accountUnknown(name):
            return "Account '\(name)' not in Mail account map"
        }
    }
}

// MARK: - Account record

/// One Mail account as the fast path needs it: the JXA-visible display name,
/// the address, and the UUID that prefixes every `mailboxes.url` in the
/// Envelope Index. Produced by the JXA accounts script (`acct.id()` == the
/// URL UUID, verified live 2026-07-15) and cached on disk.
struct MailAccountRecord: Codable, Sendable, Equatable {
    let name: String
    let email: String
    let uuid: String
}

// MARK: - Accounts cache

/// On-disk cache of the Mail account name→UUID map. The map only comes from a
/// JXA `accounts()` call (one Apple Event round-trip — normally ~1s, minutes
/// when Mail is wedged), and accounts change rarely, so the fast path never
/// pays for it twice: cached at `~/.config/pippin/mail-accounts.json`,
/// refreshed only when empty, when `--account` names something unknown, or
/// (TTL-limited) when the Envelope Index references a UUID we can't map.
enum MailAccountsCache {
    static func defaultPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/.config/pippin/mail-accounts.json"
    }

    private struct CacheFile: Codable {
        let fetchedAt: Date
        let accounts: [MailAccountRecord]
    }

    static func load(path: String = defaultPath()) -> (accounts: [MailAccountRecord], fetchedAt: Date?) {
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder.withISODates().decode(CacheFile.self, from: data)
        else { return ([], nil) }
        return (file.accounts, file.fetchedAt)
    }

    static func save(_ accounts: [MailAccountRecord], fetchedAt: Date, path: String = defaultPath()) {
        let file = CacheFile(fetchedAt: fetchedAt, accounts: accounts)
        guard let data = try? JSONEncoder.withISODates().encode(file) else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Return a usable account map for a query, fetching via JXA only when
    /// necessary: empty cache always fetches (first run); a `--account` name
    /// absent from the cache fetches once (new account); a failed fetch falls
    /// back to the stale cache when one exists (resolution then throws its own
    /// typed error → JXA fallback) and throws `accountsUnavailable` when not.
    static func ensure(
        accountName: String?,
        path: String = defaultPath(),
        fetch: () throws -> [MailAccountRecord]
    ) throws -> [MailAccountRecord] {
        let (cached, _) = load(path: path)
        let nameMiss = accountName.map { name in !cached.contains { $0.name == name } } ?? false
        guard cached.isEmpty || nameMiss else { return cached }
        do {
            let fresh = try fetch()
            save(fresh, fetchedAt: Date(), path: path)
            return fresh
        } catch {
            guard !cached.isEmpty else {
                throw MailEnvelopeIndexError.accountsUnavailable(String(describing: error))
            }
            return cached
        }
    }

    /// Whether the cache is old enough to justify a self-heal refresh when the
    /// Envelope Index references an account UUID we can't map (new account
    /// added, or a permanently unmappable UUID — the TTL stops the latter from
    /// re-triggering a JXA call on every command).
    static func isStale(fetchedAt: Date?, now: Date = Date(), ttl: TimeInterval = 3600) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > ttl
    }
}

private extension JSONDecoder {
    static func withISODates() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private extension JSONEncoder {
    static func withISODates() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

// MARK: - Reader

/// Read-only view over a snapshot of Mail's Envelope Index SQLite for
/// list/search/activity METADATA (~31ms vs 10–95s JXA budgets, pippin-60x).
///
/// Non-negotiables (from the spike):
/// - NEVER opens Mail's live DB files directly — `init(dbPath:)` copies
///   db + -wal + -shm to a private temp dir first (the WAL holds the newest
///   messages; an `immutable=1` open silently misses them).
/// - NEVER writes anything Mail-owned. The snapshot is discarded on deinit.
/// - Schema-version guard: `properties.version` must be a known value or the
///   whole fast path refuses (macOS releases can reshape this undocumented DB).
/// - Compound ids are `account||mailboxLeaf||ROWID` — byte-compatible with the
///   JXA path because Mail's AppleScript `msg.id()` IS the Envelope Index
///   ROWID (verified both directions live; an index rebuild renumbers both
///   spaces together). show/mark/move need no changes.
final class MailEnvelopeIndex: Sendable {
    /// `properties.version` values this reader understands (macOS 27β Mail V10).
    static let knownVersions: Set<Int> = [4]

    private let dbQueue: DatabaseQueue
    private let accounts: [MailAccountRecord]
    private let snapshotDir: String?

    // MARK: Paths

    /// Newest `~/Library/Mail/V*/MailData/Envelope Index` on disk. The V-number
    /// bumps across macOS releases (V10 on macOS 27) — scan rather than hardcode.
    static func defaultDBPath() -> String? {
        let mailRoot = NSHomeDirectory() + "/Library/Mail"
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: mailRoot) else { return nil }
        let versions = entries.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("V"), let n = Int(name.dropFirst()) else { return nil }
            let candidate = "\(mailRoot)/\(name)/MailData/Envelope Index"
            guard fm.fileExists(atPath: candidate) else { return nil }
            return (n, candidate)
        }
        return versions.max { $0.0 < $1.0 }?.1
    }

    // MARK: Init

    /// Snapshot-copy the live Envelope Index (db + -wal + -shm) into a private
    /// temp dir, open the copy, and validate the schema version. The copy is
    /// what makes reads safe (no lock contention with Mail) and fresh (WAL
    /// included). FDA denial surfaces as a copy failure → `.accessDenied`.
    init(dbPath: String, accounts: [MailAccountRecord]) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath) else {
            throw MailEnvelopeIndexError.databaseNotFound(dbPath)
        }
        let dir = fm.temporaryDirectory
            .appendingPathComponent("pippin-envelope-\(UUID().uuidString)").path
        let copyPath = dir + "/index.db"
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try fm.copyItem(atPath: dbPath, toPath: copyPath)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: dbPath + suffix) {
                try fm.copyItem(atPath: dbPath + suffix, toPath: copyPath + suffix)
            }
        } catch {
            try? fm.removeItem(atPath: dir)
            throw MailEnvelopeIndexError.accessDenied(error.localizedDescription)
        }
        do {
            // Writable open on OUR copy: SQLite needs to recover the copied WAL,
            // which a readonly config can refuse. Nothing here ever writes SQL.
            dbQueue = try DatabaseQueue(path: copyPath)
        } catch {
            try? fm.removeItem(atPath: dir)
            throw MailEnvelopeIndexError.accessDenied(error.localizedDescription)
        }
        self.accounts = accounts
        snapshotDir = dir
        do {
            try validateSchema()
        } catch {
            try? fm.removeItem(atPath: dir)
            throw error
        }
    }

    /// Test seam: pre-built (in-memory) queue, no snapshot.
    init(dbQueue: DatabaseQueue, accounts: [MailAccountRecord]) throws {
        self.dbQueue = dbQueue
        self.accounts = accounts
        snapshotDir = nil
        try validateSchema()
    }

    deinit {
        if let snapshotDir {
            try? FileManager.default.removeItem(atPath: snapshotDir)
        }
    }

    // MARK: Schema guard

    private func validateSchema() throws {
        let version = try dbQueue.read { db -> Int in
            let raw = try String.fetchOne(
                db, sql: "SELECT value FROM properties WHERE key = 'version'"
            )
            return raw.flatMap(Int.init) ?? 0
        }
        guard Self.knownVersions.contains(version) else {
            throw MailEnvelopeIndexError.unsupportedVersion(version)
        }
    }

    // MARK: Mailbox resolution

    private struct MailboxRef {
        let rowid: Int64
        let accountName: String
        let leaf: String
    }

    /// Special-mailbox alias groups mirroring `jsResolveMailbox` in
    /// MailBridgeHelpers.swift: a request for any name in a group matches a
    /// mailbox whose decoded URL leaf is any name in the same group (JXA maps
    /// e.g. "Trash" → `acct.trash()` whatever the provider calls it on disk).
    private static let aliasGroups: [Set<String>] = [
        ["inbox"],
        ["sent", "sent messages", "sent mail", "sent items"],
        ["trash", "deleted", "deleted messages", "deleted items", "bin"],
        ["junk", "spam"],
        ["drafts", "draft"],
    ]

    /// `scheme://ACCOUNT-UUID/percent-encoded/path` → (uuid, decoded leaf).
    /// Manual parse — Foundation URL normalizes hosts in ways we don't want.
    static func parseMailboxURL(_ url: String) -> (uuid: String, leaf: String)? {
        guard let schemeRange = url.range(of: "://") else { return nil }
        let comps = url[schemeRange.upperBound...]
            .split(separator: "/", omittingEmptySubsequences: false)
        guard comps.count >= 2, !comps[0].isEmpty,
              let last = comps.last, !last.isEmpty,
              let leaf = String(last).removingPercentEncoding
        else { return nil }
        return (String(comps[0]), leaf)
    }

    /// Resolve the mailboxes a query targets. `mailboxName == nil` means "all
    /// mailboxes of the targeted accounts" (cross-mailbox search). Throws
    /// (→ JXA fallback) when the account name is unknown or nothing matches —
    /// never silently returns [] for a resolution failure, because JXA's
    /// special-mailbox accessors can succeed where leaf-name matching can't
    /// (e.g. localized mailbox names).
    private func resolveMailboxes(accountFilter: String?, mailboxName: String?) throws -> [MailboxRef] {
        var targetUUIDs: [String: String] = [:] // uuid → account name
        if let accountFilter {
            guard let record = accounts.first(where: { $0.name == accountFilter }) else {
                throw MailEnvelopeIndexError.accountUnknown(accountFilter)
            }
            targetUUIDs[record.uuid.lowercased()] = record.name
        } else {
            for record in accounts {
                targetUUIDs[record.uuid.lowercased()] = record.name
            }
        }

        let aliasSet: Set<String>? = mailboxName.map { name in
            let lc = name.lowercased()
            return Self.aliasGroups.first { $0.contains(lc) } ?? [lc]
        }

        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT ROWID, url FROM mailboxes")
        }
        var refs: [MailboxRef] = []
        for row in rows {
            guard let rowid = row["ROWID"] as Int64?,
                  let url = row["url"] as String?,
                  let (uuid, leaf) = Self.parseMailboxURL(url),
                  let accountName = targetUUIDs[uuid.lowercased()]
            else { continue }
            if let aliasSet, !aliasSet.contains(leaf.lowercased()) { continue }
            refs.append(MailboxRef(rowid: rowid, accountName: accountName, leaf: leaf))
        }
        guard !refs.isEmpty else {
            throw MailEnvelopeIndexError.mailboxUnresolved(mailboxName ?? "(all)")
        }
        return refs
    }

    /// Account UUIDs referenced by mailbox URLs that the account map can't
    /// name. `local://` ("On My Mac") is excluded — JXA's `accounts()` never
    /// lists it, so it is invisible to BOTH paths (parity). A non-empty result
    /// means the cache may be missing a newly added account; the caller
    /// (`MailBridge.makeFastPathIndex`) refreshes the cache TTL-limited.
    func unknownAccountUUIDs() throws -> Set<String> {
        let known = Set(accounts.map { $0.uuid.lowercased() })
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT url FROM mailboxes")
        }
        var unknown = Set<String>()
        for row in rows {
            guard let url = row["url"] as String?,
                  !url.hasPrefix("local://"),
                  let (uuid, _) = Self.parseMailboxURL(url)
            else { continue }
            if !known.contains(uuid.lowercased()) { unknown.insert(uuid) }
        }
        return unknown
    }

    // MARK: Date handling

    /// `YYYY-MM-DD` → UTC midnight, matching JXA's `new Date('YYYY-MM-DD')`
    /// (JS parses date-only strings as UTC). Deliberately NOT
    /// `MailBridge.parseFilterDate`, which is local-midnight for the
    /// shortfall-hint display — using local here would drop rows near day
    /// boundaries that the JXA path keeps.
    static func parseFilterDateUTC(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    /// Byte-parity with JS `Date.toISOString()` — callers compare/sort these strings.
    private static func isoString(_ epoch: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: Row plumbing

    private struct RawRow {
        let rowid: Int64
        let mailboxRowid: Int64
        let subject: String
        let address: String
        let comment: String
        let epoch: Int64
        let read: Bool
        let size: Int?
        let hasAttachment: Bool
        let header: String?
    }

    /// The shared SELECT. `NULLIF(date, 0)` — some rows carry 0 instead of
    /// NULL; both mean "use the other date column".
    private static let baseSelect = """
    SELECT m.ROWID AS msg_rowid, m.mailbox AS mb_rowid,
           s.subject AS subj, a.address AS addr, a.comment AS cmt,
           COALESCE(NULLIF(m.date_sent, 0), NULLIF(m.date_received, 0), 0) AS epoch,
           m.read AS is_read, m.size AS size,
           EXISTS(SELECT 1 FROM attachments att WHERE att.message = m.ROWID) AS has_att,
           gd.message_id_header AS header
    FROM messages m
    LEFT JOIN subjects s ON s.ROWID = m.subject
    LEFT JOIN addresses a ON a.ROWID = m.sender
    LEFT JOIN message_global_data gd ON gd.ROWID = m.global_message_id
    """

    // Every column read is optional-with-fallback: Apple's DB can hold NULL
    // anywhere and `row["x"] as T` traps on NULL (docs/gotchas/swift.md).
    private static func rawRow(_ row: Row) -> RawRow {
        RawRow(
            rowid: row["msg_rowid"] as Int64? ?? 0,
            mailboxRowid: row["mb_rowid"] as Int64? ?? 0,
            subject: row["subj"] as String? ?? "",
            address: row["addr"] as String? ?? "",
            comment: row["cmt"] as String? ?? "",
            epoch: row["epoch"] as Int64? ?? 0,
            read: (row["is_read"] as Int64? ?? 0) != 0,
            size: (row["size"] as Int64?).map(Int.init),
            hasAttachment: (row["has_att"] as Int64? ?? 0) != 0,
            header: row["header"] as String?
        )
    }

    /// JXA emits `msg.sender()` — the raw From header ("Name <addr>" or bare
    /// address). Compose the same shape from the normalized columns.
    private static func composeFrom(address: String, comment: String) -> String {
        if comment.isEmpty { return address }
        if address.isEmpty { return comment }
        return "\(comment) <\(address)>"
    }

    private func buildMessages(
        _ raws: [RawRow],
        refsByRowid: [Int64: MailboxRef],
        populateTo: Bool
    ) throws -> [MailMessage] {
        var toByMessage: [Int64: [String]] = [:]
        if populateTo, !raws.isEmpty {
            let ids = raws.map { String($0.rowid) }.joined(separator: ",")
            let rows = try dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                SELECT r.message AS msg, ra.address AS addr
                FROM recipients r JOIN addresses ra ON ra.ROWID = r.address
                WHERE r.type = 0 AND r.message IN (\(ids))
                ORDER BY r.message, r.position
                """)
            }
            for row in rows {
                guard let msg = row["msg"] as Int64?, let addr = row["addr"] as String? else { continue }
                toByMessage[msg, default: []].append(addr)
            }
        }
        return raws.compactMap { raw in
            guard let ref = refsByRowid[raw.mailboxRowid] else { return nil }
            return MailMessage(
                id: "\(ref.accountName)||\(ref.leaf)||\(raw.rowid)",
                account: ref.accountName,
                mailbox: ref.leaf,
                subject: raw.subject,
                from: Self.composeFrom(address: raw.address, comment: raw.comment),
                to: toByMessage[raw.rowid] ?? [],
                date: Self.isoString(raw.epoch),
                read: raw.read,
                body: nil,
                size: raw.size,
                hasAttachment: raw.hasAttachment
            )
        }
    }

    /// Dedup mirroring the JXA scripts: Gmail lists the same message in both
    /// INBOX and [Gmail]/All Mail — key on the RFC Message-ID header, falling
    /// back to subject+sender+date. Order-preserving (SQL already sorted).
    private static func dedup(_ raws: [RawRow]) -> [RawRow] {
        var seen = Set<String>()
        return raws.filter { raw in
            let key = raw.header ?? "\(raw.subject)\0\(raw.address)\0\(raw.epoch)"
            return seen.insert(key).inserted
        }
    }

    private static func dateFilterSQL(after: String?, before: String?) -> String {
        var sql = ""
        if let after, let d = parseFilterDateUTC(after) {
            // JXA keeps msgDate >= afterDate
            sql += " AND epoch >= \(Int64(d.timeIntervalSince1970))"
        }
        if let before, let d = parseFilterDateUTC(before) {
            // JXA skips msgDate > beforeDate
            sql += " AND epoch <= \(Int64(d.timeIntervalSince1970))"
        }
        return sql
    }

    // MARK: - Queries

    func listMessages(
        account: String?,
        mailbox: String,
        unread: Bool,
        limit: Int,
        offset: Int,
        after: String?,
        before: String?
    ) throws -> [MailMessage] {
        let refs = try resolveMailboxes(accountFilter: account, mailboxName: mailbox)
        let rowids = refs.map { String($0.rowid) }.joined(separator: ",")
        var sql = Self.baseSelect + " WHERE m.deleted = 0 AND m.mailbox IN (\(rowids))"
        if unread { sql += " AND m.read = 0" }
        sql += Self.dateFilterSQL(after: after, before: before)
        sql += " ORDER BY epoch DESC, m.ROWID ASC LIMIT \(max(1, limit)) OFFSET \(max(0, offset))"
        let raws = try dbQueue.read { db in try Row.fetchAll(db, sql: sql) }.map(Self.rawRow)
        return try buildMessages(
            raws,
            refsByRowid: Dictionary(uniqueKeysWithValues: refs.map { ($0.rowid, $0) }),
            populateTo: false // JXA list rows emit to: [] — parity
        )
    }

    /// Safety cap on pre-dedup candidate rows for search/activity. Far above
    /// any real limit (CLI clamps limit to 500); keeps a pathological LIKE
    /// from materializing the whole 28k-row table.
    private static let candidateCap = 5000

    func searchMessages(
        query: String,
        account: String?,
        mailbox: String?,
        limit: Int,
        offset: Int,
        after: String?,
        before: String?,
        to: String?,
        from: String?
    ) throws -> [MailMessage] {
        let refs = try resolveMailboxes(accountFilter: account, mailboxName: mailbox)
        let rowids = refs.map { String($0.rowid) }.joined(separator: ",")
        // JXA parity: case-insensitive substring over subject OR the composed
        // sender string ("Name <addr>"). LIKE ... COLLATE NOCASE is ASCII-only
        // case folding vs JS toLowerCase's Unicode folding — accepted drift.
        var sql = Self.baseSelect + """
         WHERE m.deleted = 0 AND m.mailbox IN (\(rowids))
         AND (COALESCE(s.subject, '') LIKE '%' || :query || '%' COLLATE NOCASE
              OR COALESCE(a.comment, '') || ' <' || COALESCE(a.address, '') || '>'
                 LIKE '%' || :query || '%' COLLATE NOCASE)
        """
        var arguments: [String: (any DatabaseValueConvertible)?] = ["query": query]
        if let from {
            sql += """
             AND COALESCE(a.comment, '') || ' <' || COALESCE(a.address, '') || '>'
                 LIKE '%' || :from || '%' COLLATE NOCASE
            """
            arguments["from"] = from
        }
        if let to {
            // JXA checks toRecipients().address() only (type 0, addresses not names).
            sql += """
             AND EXISTS(SELECT 1 FROM recipients r JOIN addresses ra ON ra.ROWID = r.address
                        WHERE r.message = m.ROWID AND r.type = 0
                          AND ra.address LIKE '%' || :to || '%' COLLATE NOCASE)
            """
            arguments["to"] = to
        }
        sql += Self.dateFilterSQL(after: after, before: before)
        sql += " ORDER BY epoch DESC, m.ROWID ASC LIMIT \(Self.candidateCap)"
        let fetched = try dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }.map(Self.rawRow)
        // JXA applies offset AFTER dedup.
        let deduped = Self.dedup(fetched)
        let window = Array(deduped.dropFirst(max(0, offset)).prefix(max(1, limit)))
        return try buildMessages(
            window,
            refsByRowid: Dictionary(uniqueKeysWithValues: refs.map { ($0.rowid, $0) }),
            populateTo: true
        )
    }

    func listActivity(
        account: String?,
        mailboxes: [String],
        since: Date?,
        limit: Int
    ) throws -> [MailMessage] {
        var refs: [MailboxRef] = []
        for name in mailboxes {
            refs += try resolveMailboxes(accountFilter: account, mailboxName: name)
        }
        let rowids = refs.map { String($0.rowid) }.joined(separator: ",")
        var sql = Self.baseSelect + " WHERE m.deleted = 0 AND m.mailbox IN (\(rowids))"
        if let since {
            sql += " AND epoch >= \(Int64(since.timeIntervalSince1970))"
        }
        sql += " ORDER BY epoch DESC, m.ROWID ASC LIMIT \(Self.candidateCap)"
        let fetched = try dbQueue.read { db in try Row.fetchAll(db, sql: sql) }.map(Self.rawRow)
        let window = Array(Self.dedup(fetched).prefix(max(1, limit)))
        return try buildMessages(
            window,
            refsByRowid: Dictionary(uniqueKeysWithValues: refs.map { ($0.rowid, $0) }),
            populateTo: true
        )
    }
}
