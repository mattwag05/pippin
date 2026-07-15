import Foundation
import GRDB
@testable import PippinLib
import XCTest

/// Unit tests for the Envelope Index fast path (pippin-60x). Uses an in-memory
/// GRDB queue seeded with the minimal slice of Mail's Envelope Index schema
/// the reader touches — same pattern as VoiceMemosDBTests (CI-safe, no Mail.app,
/// no Full Disk Access).
final class MailEnvelopeIndexTests: XCTestCase {
    // MARK: - Fixture

    static let uuidA = "AAAAAAAA-1111-1111-1111-111111111111" // "Personal" (imap)
    static let uuidB = "BBBBBBBB-2222-2222-2222-222222222222" // "Work" (ews)
    static let uuidGhost = "EEEEEEEE-9999-9999-9999-999999999999" // not in accounts

    static let accounts: [MailAccountRecord] = [
        MailAccountRecord(name: "Personal", email: "p@example.com", uuid: uuidA),
        MailAccountRecord(name: "Work", email: "w@example.com", uuid: uuidB),
    ]

    /// Epochs chosen so ordering is unambiguous. 2026-07-10T00:00:00Z.
    static let jul10 = 1_783_987_200
    static let hour = 3600

    private func makeSchemaDB(version: String = "4") throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE properties (ROWID INTEGER PRIMARY KEY, key TEXT, value TEXT);
            CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT NOT NULL, source INTEGER);
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
            CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT);
            CREATE TABLE messages (
                ROWID INTEGER PRIMARY KEY,
                global_message_id INTEGER NOT NULL DEFAULT 0,
                sender INTEGER,
                subject INTEGER NOT NULL,
                date_sent INTEGER,
                date_received INTEGER,
                mailbox INTEGER NOT NULL,
                read INTEGER NOT NULL DEFAULT 0,
                flagged INTEGER NOT NULL DEFAULT 0,
                deleted INTEGER NOT NULL DEFAULT 0,
                size INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER NOT NULL,
                address INTEGER NOT NULL, type INTEGER, position INTEGER);
            CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INTEGER NOT NULL, name TEXT);
            """)
            try db.execute(
                sql: "INSERT INTO properties (key, value) VALUES ('version', ?), ('minor_version', '90006')",
                arguments: [version]
            )
        }
        return q
    }

    /// Full fixture: 2 known accounts + 1 ghost, mailboxes with provider-specific
    /// special names, messages spanning read/unread/deleted/dates/attachments.
    private func makeFixtureDB() throws -> DatabaseQueue {
        let q = try makeSchemaDB()
        try q.write { db in
            try db.execute(sql: """
            INSERT INTO mailboxes (ROWID, url) VALUES
              (1, 'imap://\(Self.uuidA)/INBOX'),
              (2, 'imap://\(Self.uuidA)/Sent%20Messages'),
              (3, 'imap://\(Self.uuidA)/%5BGmail%5D/All%20Mail'),
              (4, 'ews://\(Self.uuidB)/Inbox'),
              (5, 'ews://\(Self.uuidB)/Sent%20Items'),
              (6, 'ews://\(Self.uuidB)/Deleted%20Items'),
              (7, 'imap://\(Self.uuidGhost)/INBOX');

            INSERT INTO subjects (ROWID, subject) VALUES
              (1, 'Build succeeded'),
              (2, 'Lunch tomorrow?'),
              (3, 'Invoice #42 attached'),
              (4, 'Re: Lunch tomorrow?'),
              (5, 'Old newsletter'),
              (6, 'Deleted thing'),
              (7, 'Ghost message');

            INSERT INTO addresses (ROWID, address, comment) VALUES
              (1, 'ci@example.com', 'CI Bot'),
              (2, 'friend@example.com', NULL),
              (3, 'billing@vendor.com', 'Vendor Billing'),
              (4, 'p@example.com', 'Me'),
              (5, 'w@example.com', NULL);

            INSERT INTO message_global_data (ROWID, message_id_header) VALUES
              (1, '<build-1@ci.example.com>'),
              (2, '<lunch-2@friend.example.com>'),
              (3, '<invoice-3@vendor.com>'),
              (4, '<reply-4@p.example.com>'),
              (5, '<news-5@list.example.com>'),
              (6, '<deleted-6@x.com>');
            """)
            // Personal INBOX: rowids 101 (newest, unread, CI), 102 (read, friend),
            // 105 (old newsletter, read). Gmail All Mail duplicates 101's header
            // (rowid 103) — dedup target. Personal Sent Messages: 104 (from Me).
            // Work Inbox: 201 (unread, vendor, attachment, date_sent NULL).
            // Work Sent Items: 202. Work Deleted Items: 203. Deleted-flag row 106
            // in Personal INBOX. Ghost INBOX: 301.
            try db.execute(sql: """
            INSERT INTO messages (ROWID, global_message_id, sender, subject, date_sent, date_received, mailbox, read, deleted, size) VALUES
              (101, 1, 1, 1, \(Self.jul10 + 3 * Self.hour), \(Self.jul10 + 3 * Self.hour + 10), 1, 0, 0, 1000),
              (102, 2, 2, 2, \(Self.jul10 + 2 * Self.hour), \(Self.jul10 + 2 * Self.hour + 10), 1, 1, 0, 2000),
              (105, 5, 2, 5, \(Self.jul10 - 30 * 24 * Self.hour), \(Self.jul10 - 30 * 24 * Self.hour), 1, 1, 0, 500),
              (103, 1, 1, 1, \(Self.jul10 + 3 * Self.hour), \(Self.jul10 + 3 * Self.hour + 10), 3, 0, 0, 1000),
              (104, 4, 4, 4, \(Self.jul10 + 1 * Self.hour), \(Self.jul10 + 1 * Self.hour), 2, 1, 0, 800),
              (201, 3, 3, 3, NULL, \(Self.jul10 + 4 * Self.hour), 4, 0, 0, 3000),
              (202, 4, 5, 4, \(Self.jul10 + 30 * 60), \(Self.jul10 + 30 * 60), 5, 1, 0, 900),
              (203, 6, 2, 6, \(Self.jul10), \(Self.jul10), 6, 1, 0, 100),
              (106, 6, 2, 6, \(Self.jul10 + 5 * Self.hour), \(Self.jul10 + 5 * Self.hour), 1, 0, 1, 100),
              (301, 0, 2, 7, \(Self.jul10 + 6 * Self.hour), \(Self.jul10 + 6 * Self.hour), 7, 0, 0, 100);

            INSERT INTO recipients (message, address, type, position) VALUES
              (101, 4, 0, 0),
              (102, 4, 0, 0),
              (201, 5, 0, 0),
              (201, 4, 1, 1),
              (202, 3, 0, 0);

            INSERT INTO attachments (message, name) VALUES (201, 'invoice.pdf');
            """)
        }
        return q
    }

    private func makeIndex(_ q: DatabaseQueue? = nil) throws -> MailEnvelopeIndex {
        try MailEnvelopeIndex(dbQueue: q ?? makeFixtureDB(), accounts: Self.accounts)
    }

    private func iso(_ epoch: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    // MARK: - Schema guard

    func testVersionGuardAcceptsV4() throws {
        XCTAssertNoThrow(try makeIndex())
    }

    func testVersionGuardRejectsUnknownVersion() throws {
        let q = try makeSchemaDB(version: "5")
        XCTAssertThrowsError(try MailEnvelopeIndex(dbQueue: q, accounts: Self.accounts)) { error in
            guard case MailEnvelopeIndexError.unsupportedVersion(5) = error else {
                XCTFail("Expected unsupportedVersion(5), got \(error)"); return
            }
        }
    }

    func testVersionGuardRejectsMissingProperties() throws {
        let q = try DatabaseQueue()
        try q.write { db in
            try db.execute(sql: "CREATE TABLE properties (ROWID INTEGER PRIMARY KEY, key TEXT, value TEXT)")
        }
        XCTAssertThrowsError(try MailEnvelopeIndex(dbQueue: q, accounts: Self.accounts))
    }

    // MARK: - List

    func testListNewestFirstWithRowidCompoundIds() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: "Personal", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs.map(\.id), [
            "Personal||INBOX||101",
            "Personal||INBOX||102",
            "Personal||INBOX||105",
        ])
        XCTAssertEqual(msgs[0].subject, "Build succeeded")
        XCTAssertEqual(msgs[0].account, "Personal")
        XCTAssertEqual(msgs[0].mailbox, "INBOX")
        XCTAssertFalse(msgs[0].read)
        XCTAssertTrue(msgs[1].read)
        XCTAssertEqual(msgs[0].size, 1000)
        XCTAssertEqual(msgs[0].date, iso(Self.jul10 + 3 * Self.hour))
        XCTAssertEqual(msgs[0].to, []) // list rows don't populate to (JXA parity)
    }

    func testListLimitAndOffset() throws {
        let idx = try makeIndex()
        let page2 = try idx.listMessages(
            account: "Personal", mailbox: "INBOX", unread: false,
            limit: 1, offset: 1, after: nil, before: nil
        )
        XCTAssertEqual(page2.map(\.id), ["Personal||INBOX||102"])
    }

    func testListUnreadOnly() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: "Personal", mailbox: "INBOX", unread: true,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Personal||INBOX||101"])
    }

    func testListExcludesDeletedRows() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: "Personal", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertFalse(msgs.contains { $0.subject == "Deleted thing" })
    }

    func testListInboxAliasMatchesEwsInboxLeaf() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: "Work", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Work||Inbox||201"])
        // mailbox component is the decoded leaf (what JXA mb.name() returns)
        XCTAssertEqual(msgs[0].mailbox, "Inbox")
        XCTAssertEqual(msgs[0].hasAttachment, true)
    }

    func testListCrossAccountGlobalNewestFirst() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: nil, mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        // Work 201 (jul10+4h via date_received fallback) > Personal 101 (+3h) > 102 > 105.
        // Ghost account's message must not appear.
        XCTAssertEqual(msgs.map(\.id), [
            "Work||Inbox||201",
            "Personal||INBOX||101",
            "Personal||INBOX||102",
            "Personal||INBOX||105",
        ])
    }

    func testListDateSentNullFallsBackToDateReceived() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: "Work", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs[0].date, iso(Self.jul10 + 4 * Self.hour))
    }

    func testListAfterIsUTCMidnightInclusive() throws {
        let idx = try makeIndex()
        // --after 2026-07-10 must include everything on jul10 (UTC) and exclude
        // the 30-day-old newsletter. JXA parses 'YYYY-MM-DD' as UTC midnight.
        let msgs = try idx.listMessages(
            account: "Personal", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: "2026-07-10", before: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Personal||INBOX||101", "Personal||INBOX||102"])
    }

    func testListBeforeIsUTCMidnightInclusive() throws {
        let idx = try makeIndex()
        // JXA: skip when msgDate > beforeDate — so --before 2026-07-10 keeps only
        // messages at/before 2026-07-10T00:00:00Z. Newsletter qualifies.
        let msgs = try idx.listMessages(
            account: "Personal", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: "2026-07-10"
        )
        XCTAssertEqual(msgs.map(\.id), ["Personal||INBOX||105"])
    }

    func testFromComposition() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: "Personal", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs[0].from, "CI Bot <ci@example.com>") // comment + address
        XCTAssertEqual(msgs[1].from, "friend@example.com") // no comment → bare address
    }

    func testNullToleranceEverywhere() throws {
        // A pathological row: NULL sender, NULL dates, NULL header, subject row
        // missing. Must not trap (GRDB row["x"] NULL trap) and must not crash
        // the whole list.
        let q = try makeFixtureDB()
        try q.write { db in
            try db.execute(sql: """
            INSERT INTO messages (ROWID, global_message_id, sender, subject, date_sent, date_received, mailbox, read, deleted, size)
            VALUES (999, 0, NULL, 888, NULL, NULL, 1, 0, 0, 0)
            """)
        }
        let idx = try makeIndex(q)
        let msgs = try idx.listMessages(
            account: "Personal", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        let ghost = msgs.first { $0.id == "Personal||INBOX||999" }
        XCTAssertNotNil(ghost)
        XCTAssertEqual(ghost?.subject, "")
        XCTAssertEqual(ghost?.from, "")
    }

    // MARK: - Mailbox alias resolution

    func testSentAliasResolvesProviderVariants() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: nil, mailbox: "Sent", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        // Personal "Sent Messages" + Work "Sent Items", newest first.
        XCTAssertEqual(msgs.map(\.id), ["Personal||Sent Messages||104", "Work||Sent Items||202"])
    }

    func testTrashAliasResolvesDeletedItems() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: "Work", mailbox: "Trash", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Work||Deleted Items||203"])
    }

    func testExactLeafMatchForNestedMailbox() throws {
        let idx = try makeIndex()
        let msgs = try idx.listMessages(
            account: "Personal", mailbox: "All Mail", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Personal||All Mail||103"])
    }

    func testUnresolvedMailboxThrows() throws {
        let idx = try makeIndex()
        XCTAssertThrowsError(try idx.listMessages(
            account: "Personal", mailbox: "NoSuchBox", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )) { error in
            guard case MailEnvelopeIndexError.mailboxUnresolved = error else {
                XCTFail("Expected mailboxUnresolved, got \(error)"); return
            }
        }
    }

    func testUnknownAccountNameThrows() throws {
        let idx = try makeIndex()
        XCTAssertThrowsError(try idx.listMessages(
            account: "Nope", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )) { error in
            guard case MailEnvelopeIndexError.accountUnknown = error else {
                XCTFail("Expected accountUnknown, got \(error)"); return
            }
        }
    }

    // MARK: - Search

    func testSearchSubjectCaseInsensitive() throws {
        let idx = try makeIndex()
        let msgs = try idx.searchMessages(
            query: "lunch", account: nil, mailbox: nil,
            limit: 10, offset: 0, after: nil, before: nil, to: nil, from: nil
        )
        XCTAssertEqual(Set(msgs.map(\.subject)), ["Lunch tomorrow?", "Re: Lunch tomorrow?"])
        // Search rows populate to (JXA parity).
        let lunch = msgs.first { $0.id == "Personal||INBOX||102" }
        XCTAssertEqual(lunch?.to, ["p@example.com"])
    }

    func testSearchMatchesSenderNameAndAddress() throws {
        let idx = try makeIndex()
        let byName = try idx.searchMessages(
            query: "ci bot", account: nil, mailbox: nil,
            limit: 10, offset: 0, after: nil, before: nil, to: nil, from: nil
        )
        XCTAssertTrue(byName.contains { $0.id == "Personal||INBOX||101" })
        let byAddr = try idx.searchMessages(
            query: "billing@vendor.com", account: nil, mailbox: nil,
            limit: 10, offset: 0, after: nil, before: nil, to: nil, from: nil
        )
        XCTAssertEqual(byAddr.map(\.id), ["Work||Inbox||201"])
    }

    func testSearchDedupsAcrossMailboxesByHeader() throws {
        let idx = try makeIndex()
        // "Build succeeded" exists in Personal INBOX (101) and All Mail (103)
        // with the same message_id_header — must dedup to one row.
        let msgs = try idx.searchMessages(
            query: "build succeeded", account: nil, mailbox: nil,
            limit: 10, offset: 0, after: nil, before: nil, to: nil, from: nil
        )
        XCTAssertEqual(msgs.count, 1)
    }

    func testSearchFromFilter() throws {
        let idx = try makeIndex()
        let msgs = try idx.searchMessages(
            query: "lunch", account: nil, mailbox: nil,
            limit: 10, offset: 0, after: nil, before: nil, to: nil, from: "friend@"
        )
        XCTAssertEqual(msgs.map(\.id), ["Personal||INBOX||102"])
    }

    func testSearchToFilter() throws {
        let idx = try makeIndex()
        let msgs = try idx.searchMessages(
            query: "invoice", account: nil, mailbox: nil,
            limit: 10, offset: 0, after: nil, before: nil, to: "w@example.com", from: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Work||Inbox||201"])
        // to filter matches only type=0 recipients; w@ is To on 201.
    }

    func testSearchMailboxScoped() throws {
        let idx = try makeIndex()
        let msgs = try idx.searchMessages(
            query: "lunch", account: "Personal", mailbox: "Sent",
            limit: 10, offset: 0, after: nil, before: nil, to: nil, from: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Personal||Sent Messages||104"])
    }

    // MARK: - Gate + self-heal plumbing

    func testFastPathEnabledEnvKillSwitchWins() throws {
        let config = try JSONDecoder().decode(
            PippinConfig.self, from: Data(#"{"mail":{"fastPath":true}}"#.utf8)
        )
        XCTAssertFalse(MailBridge.fastPathEnabled(env: ["PIPPIN_MAIL_FASTPATH": "0"], config: config))
    }

    func testFastPathEnabledConfigOff() throws {
        let config = try JSONDecoder().decode(
            PippinConfig.self, from: Data(#"{"mail":{"fastPath":false}}"#.utf8)
        )
        XCTAssertFalse(MailBridge.fastPathEnabled(env: [:], config: config))
    }

    func testFastPathEnabledDefaultsOn() {
        XCTAssertTrue(MailBridge.fastPathEnabled(env: [:], config: nil))
    }

    func testUnknownAccountUUIDsReportsGhostButNotLocal() throws {
        let q = try makeFixtureDB()
        try q.write { db in
            try db.execute(sql: """
            INSERT INTO mailboxes (ROWID, url) VALUES
              (8, 'local://CCCCCCCC-3333-3333-3333-333333333333/Archive')
            """)
        }
        let idx = try MailEnvelopeIndex(dbQueue: q, accounts: Self.accounts)
        XCTAssertEqual(try idx.unknownAccountUUIDs(), [Self.uuidGhost])
    }

    // MARK: - Activity

    func testActivityCombinesInboxAndSentNewestFirst() throws {
        let idx = try makeIndex()
        let msgs = try idx.listActivity(
            account: "Personal", mailboxes: ["INBOX", "Sent"], since: nil, limit: 50
        )
        XCTAssertEqual(msgs.map(\.id), [
            "Personal||INBOX||101",
            "Personal||INBOX||102",
            "Personal||Sent Messages||104",
            "Personal||INBOX||105",
        ])
        // Activity rows populate to.
        XCTAssertEqual(msgs[0].to, ["p@example.com"])
    }

    func testActivitySinceFilter() throws {
        let idx = try makeIndex()
        let since = Date(timeIntervalSince1970: TimeInterval(Self.jul10 + 90 * 60))
        let msgs = try idx.listActivity(
            account: "Personal", mailboxes: ["INBOX", "Sent"], since: since, limit: 50
        )
        XCTAssertEqual(msgs.map(\.id), ["Personal||INBOX||101", "Personal||INBOX||102"])
    }

    func testActivityCrossAccountDedupsAndOrders() throws {
        let idx = try makeIndex()
        let msgs = try idx.listActivity(
            account: nil, mailboxes: ["INBOX", "Sent"], since: nil, limit: 3
        )
        XCTAssertEqual(msgs.map(\.id), [
            "Work||Inbox||201",
            "Personal||INBOX||101",
            "Personal||INBOX||102",
        ])
    }
}
