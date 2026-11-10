import Foundation
import GRDB

/// One mailbox as a mail store key. Names match what Mail's scripting returns,
/// so compound ids built from them work with show, mark and move.
struct MailboxKey: Hashable, Encodable, Sendable {
    let account: String
    let mailbox: String
}

/// A message's fields that never change. Read state and identity are not here:
/// they are read live on every answer, because Mail has no trustworthy change
/// signal (`mb.unreadCount` under-reports, pippin-zxsq).
struct MailMetaRow: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "messages"

    var compoundId: String
    var account: String
    var mailbox: String
    var rowId: String
    var dateSent: String?
    var dateReceived: String?
    var subject: String
    var sender: String
    var size: Int?
    var hasAttachment: Bool?
    var rfcMessageId: String?

    enum CodingKeys: String, CodingKey {
        case compoundId = "compound_id"
        case account, mailbox
        case rowId = "row_id"
        case dateSent = "date_sent"
        case dateReceived = "date_received"
        case subject, sender, size
        case hasAttachment = "has_attachment"
        case rfcMessageId = "rfc_message_id"
    }

    /// The date a live read is compared with: Mail can reassign numeric ids.
    var operationalDate: String? { dateReceived ?? dateSent }

    var key: MailboxKey { MailboxKey(account: account, mailbox: mailbox) }
}

struct MailMailboxScan: Equatable, Sendable {
    let key: MailboxKey
    let complete: Bool
    let updatedAt: Date
}

/// Pippin's own index of mail metadata (`~/.config/pippin/mail-meta.db`), which
/// needs no Full Disk Access. Filled over Automation by `mail cache fill`; each
/// mailbox is written in one transaction, so an interrupted fill resumes at the
/// next mailbox and readers never see a half-written one.
final class MailMetaStore: Sendable {
    static let shared: MailMetaStore? = try? MailMetaStore()

    static func defaultStorePath() -> String {
        "\(NSHomeDirectory())/.config/pippin/mail-meta.db"
    }

    private let dbQueue: DatabaseQueue

    init(dbPath: String? = nil) throws {
        dbQueue = try openCacheQueue(path: dbPath ?? Self.defaultStorePath())
        try dbQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS messages (
                compound_id TEXT PRIMARY KEY,
                account TEXT NOT NULL,
                mailbox TEXT NOT NULL,
                row_id TEXT NOT NULL,
                date_sent TEXT,
                date_received TEXT,
                subject TEXT NOT NULL,
                sender TEXT NOT NULL,
                size INTEGER,
                has_attachment INTEGER,
                rfc_message_id TEXT
            )
            """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS messages_mailbox ON messages (account, mailbox)")
            try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS mailbox_scan (
                account TEXT NOT NULL,
                mailbox TEXT NOT NULL,
                complete INTEGER NOT NULL,
                updated_at REAL NOT NULL,
                PRIMARY KEY (account, mailbox)
            )
            """)
        }
    }

    /// Replace a mailbox's rows and mark it complete. Attachment flags are read
    /// lazily, so one known for the same message survives a refresh.
    func replaceMailbox(_ key: MailboxKey, rows: [MailMetaRow], now: Date = Date()) throws {
        try dbQueue.write { db in
            let previous = try MailMetaRow.filter(Column("account") == key.account && Column("mailbox") == key.mailbox)
                .fetchAll(db)
            let known = Dictionary(previous.map { ($0.compoundId, $0) }, uniquingKeysWith: { first, _ in first })
            try db.execute(
                sql: "DELETE FROM messages WHERE account = ? AND mailbox = ?",
                arguments: [key.account, key.mailbox]
            )
            for var row in rows {
                if row.hasAttachment == nil, let old = known[row.compoundId],
                   old.operationalDate == row.operationalDate {
                    row.hasAttachment = old.hasAttachment
                }
                try row.insert(db, onConflict: .replace)
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO mailbox_scan (account, mailbox, complete, updated_at) VALUES (?, ?, 1, ?)",
                arguments: [key.account, key.mailbox, now.timeIntervalSince1970]
            )
        }
    }

    /// A failed fill leaves the mailbox marked incomplete, so readers skip it.
    func markIncomplete(_ key: MailboxKey, now: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO mailbox_scan (account, mailbox, complete, updated_at) VALUES (?, ?, 0, ?)",
                arguments: [key.account, key.mailbox, now.timeIntervalSince1970]
            )
        }
    }

    func scans() throws -> [MailMailboxScan] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT account, mailbox, complete, updated_at FROM mailbox_scan").map { row in
                MailMailboxScan(
                    key: MailboxKey(account: row["account"], mailbox: row["mailbox"]),
                    complete: row["complete"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
        }
    }

    func rows(in key: MailboxKey) throws -> [MailMetaRow] {
        try dbQueue.read { db in
            try MailMetaRow.filter(Column("account") == key.account && Column("mailbox") == key.mailbox).fetchAll(db)
        }
    }

    func setAttachmentFlags(_ flags: [String: Bool]) throws {
        guard !flags.isEmpty else { return }
        try dbQueue.write { db in
            for (compoundId, value) in flags {
                try db.execute(
                    sql: "UPDATE messages SET has_attachment = ? WHERE compound_id = ?",
                    arguments: [value, compoundId]
                )
            }
        }
    }
}

/// One live bulk read of a mailbox's changing fields and identity.
struct MailLiveMailbox: Decodable, Sendable {
    let account: String
    let mailbox: String
    let ids: [String]
    let dates: [String?]
    let read: [Bool]

    var key: MailboxKey { MailboxKey(account: account, mailbox: mailbox) }
}

/// Per-message facts for rows about to be returned.
struct MailLiveFacts: Decodable, Sendable {
    let hasAttachment: Bool?
    let messageId: String?
    let dateSent: String?
}

/// Answers list and search from the store plus one live bulk read. Stored rows
/// are trusted only when the live read vouches for them. Returning `nil` means
/// the store cannot answer and the caller should read Mail directly.
struct MailMetaReader {
    let store: MailMetaStore
    var volatile: ([MailboxKey]) throws -> [MailLiveMailbox]
    var refresh: (MailboxKey) throws -> [MailMetaRow]
    var pageFacts: ([String]) throws -> [String: MailLiveFacts]

    /// The mailboxes a request covers, or `nil` unless the store holds all of them.
    func scope(account: String?, mailbox: String?) throws -> [MailboxKey]? {
        let scans = try store.scans().filter { account == nil || $0.key.account == account }
        guard !scans.isEmpty else { return nil }
        guard let mailbox else {
            return scans.allSatisfy(\.complete) ? scans.map(\.key) : nil
        }
        let matched = scans.filter { $0.key.mailbox.caseInsensitiveCompare(mailbox) == .orderedSame }
        guard !matched.isEmpty, matched.allSatisfy(\.complete) else { return nil }
        return matched.map(\.key)
    }

    private struct Candidate {
        let row: MailMetaRow
        let read: Bool
    }

    func answer(
        scope: [MailboxKey],
        limit: Int,
        offset: Int,
        include: (MailMetaRow, Bool) -> Bool
    ) throws -> [MailMessage]? {
        var mustRefresh = Set<MailboxKey>()
        for _ in 0 ..< 2 {
            let live = try volatile(scope)
            guard Set(live.map(\.key)) == Set(scope) else { return nil }

            var candidates: [Candidate] = []
            var dateCounts: [String: Int] = [:]
            for mailbox in live {
                guard mailbox.ids.count == mailbox.dates.count, mailbox.ids.count == mailbox.read.count else { return nil }
                var rows = try Dictionary(
                    store.rows(in: mailbox.key).map { ($0.rowId, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let isStale = mailbox.ids.indices.contains { index in
                    rows[mailbox.ids[index]]?.operationalDate != mailbox.dates[index]
                }
                if isStale || mustRefresh.contains(mailbox.key) {
                    // A new id or a reassigned one: read this mailbox live and write it through.
                    let fresh = try refresh(mailbox.key)
                    try store.replaceMailbox(mailbox.key, rows: fresh)
                    rows = Dictionary(fresh.map { ($0.rowId, $0) }, uniquingKeysWith: { first, _ in first })
                }
                for index in mailbox.ids.indices {
                    guard let row = rows[mailbox.ids[index]], row.operationalDate == mailbox.dates[index] else {
                        return nil // The mailbox moved between the two reads.
                    }
                    if let date = row.operationalDate {
                        dateCounts[Self.collisionKey(mailbox.key, date), default: 0] += 1
                    }
                    if include(row, mailbox.read[index]) {
                        candidates.append(Candidate(row: row, read: mailbox.read[index]))
                    }
                }
            }

            candidates.sort(by: Self.newestFirst)
            let page = Array(Self.dedupe(candidates).dropFirst(offset).prefix(limit))
            let collided = page.filter { candidate in
                candidate.row.operationalDate.map {
                    (dateCounts[Self.collisionKey(candidate.row.key, $0)] ?? 0) > 1
                } ?? false
            }
            let needed = page.filter { $0.row.hasAttachment == nil || collided.map(\.row.compoundId).contains($0.row.compoundId) }
            var facts: [String: MailLiveFacts] = [:]
            if !needed.isEmpty {
                do {
                    facts = try pageFacts(needed.map(\.row.compoundId))
                } catch {
                    // Attachment flags are optional; a collision's identity is not.
                    if !collided.isEmpty { return nil }
                }
            }

            // Same date, so only the RFC Message-ID can tell these rows apart.
            var verdictFailed = Set<MailboxKey>()
            var unresolved = false
            for candidate in collided {
                guard let stored = candidate.row.rfcMessageId,
                      let current = facts[candidate.row.compoundId]?.messageId
                else {
                    unresolved = true
                    continue
                }
                if stored != current { verdictFailed.insert(candidate.row.key) }
            }
            if unresolved { return nil }
            if !verdictFailed.isEmpty {
                mustRefresh.formUnion(verdictFailed)
                continue
            }

            var attachmentFlags: [String: Bool] = [:]
            for (id, fact) in facts {
                if let value = fact.hasAttachment { attachmentFlags[id] = value }
            }
            try? store.setAttachmentFlags(attachmentFlags)
            return page.map { candidate in
                Self.message(
                    candidate.row, read: candidate.read,
                    hasAttachment: candidate.row.hasAttachment ?? attachmentFlags[candidate.row.compoundId]
                )
            }
        }
        return nil
    }

    private static func collisionKey(_ key: MailboxKey, _ date: String) -> String {
        "\(key.account)||\(key.mailbox)||\(date)"
    }

    private static func newestFirst(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let left = lhs.row.operationalDate ?? ""
        let right = rhs.row.operationalDate ?? ""
        if left != right { return left > right }
        return (Int(lhs.row.rowId) ?? 0) < (Int(rhs.row.rowId) ?? 0)
    }

    /// Gmail lists one message in both INBOX and All Mail.
    private static func dedupe(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            guard let id = candidate.row.rfcMessageId, !id.isEmpty else { return true }
            return seen.insert(id).inserted
        }
    }

    private static func message(_ row: MailMetaRow, read: Bool, hasAttachment: Bool?) -> MailMessage {
        MailMessage(
            id: row.compoundId, account: row.account, mailbox: row.mailbox,
            subject: row.subject, from: row.sender, to: [],
            date: row.dateSent ?? row.dateReceived ?? "",
            receivedAt: row.dateReceived, read: read, size: row.size, hasAttachment: hasAttachment,
            messageIdHeader: row.rfcMessageId.map(MailBridge.normalizeMessageId).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
