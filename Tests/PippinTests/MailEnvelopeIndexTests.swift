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
            CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER,
                PRIMARY KEY(message_id, mailbox_id)) WITHOUT ROWID;
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

    // MARK: - Mailbox counts (status fast path)

    func testMailboxCountsByAccount() throws {
        let counts = try makeIndex().mailboxCountsByAccount()
        // Personal (uuidA): INBOX, Sent Messages, [Gmail]/All Mail = 3.
        // Work (uuidB): Inbox, Sent Items, Deleted Items = 3.
        // Ghost account's mailbox (uuidGhost) isn't in `accounts`, so it's
        // excluded — keys mirror the known account set exactly.
        XCTAssertEqual(counts, ["Personal": 3, "Work": 3])
    }

    func testMailboxCountsAccountWithNoMailboxesIsZeroNotAbsent() throws {
        let q = try makeSchemaDB()
        try q.write { db in
            // Only Personal has a mailbox row; Work has none.
            try db.execute(sql: "INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://\(Self.uuidA)/INBOX');")
        }
        let counts = try makeIndex(q).mailboxCountsByAccount()
        XCTAssertEqual(counts["Personal"], 1)
        XCTAssertEqual(counts["Work"], 0, "an account with no index rows must report 0, not be missing")
    }

    func testMailboxCountsExcludesLocalOnMyMac() throws {
        let q = try makeSchemaDB()
        try q.write { db in
            try db.execute(sql: """
            INSERT INTO mailboxes (ROWID, url) VALUES
              (1, 'imap://\(Self.uuidA)/INBOX'),
              (2, 'local://Notes');
            """)
        }
        let counts = try makeIndex(q).mailboxCountsByAccount()
        XCTAssertEqual(counts["Personal"], 1, "local:// mailboxes are invisible to JXA accounts(), so excluded for parity")
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

    // MARK: - Summaries (pippin-521)

    /// Fixture + the summaries slice: only message 101 carries a snippet;
    /// 102's summary column is NULL and 105 references a missing row.
    private func makeSummariesDB() throws -> DatabaseQueue {
        let q = try makeFixtureDB()
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE summaries (ROWID INTEGER PRIMARY KEY, summary TEXT NOT NULL);
            INSERT INTO summaries (ROWID, summary) VALUES (1, 'CI build for main finished successfully.');
            ALTER TABLE messages ADD COLUMN summary INTEGER;
            UPDATE messages SET summary = 1 WHERE ROWID = 101;
            UPDATE messages SET summary = 99 WHERE ROWID = 105;
            """)
        }
        return q
    }

    func testSummariesByCompoundIdReturnsOnlyPopulatedRows() throws {
        let idx = try makeIndex(makeSummariesDB())
        let result = try idx.summariesByCompoundId(for: [
            "Personal||INBOX||101", // has a snippet
            "Personal||INBOX||102", // summary NULL
            "Personal||INBOX||105", // dangling summary ref
            "garbage-id", // unparseable → ignored
        ])
        XCTAssertEqual(result, ["Personal||INBOX||101": "CI build for main finished successfully."])
    }

    func testSummariesByCompoundIdEmptyInput() throws {
        let idx = try makeIndex(makeSummariesDB())
        XCTAssertEqual(try idx.summariesByCompoundId(for: []), [:])
        XCTAssertEqual(try idx.summariesByCompoundId(for: ["nope"]), [:])
    }

    // MARK: - Gmail label mailboxes (pippin-z0f6)

    static let uuidG = "GGGGGGGG-3333-3333-3333-333333333333" // "Gmail" (imap, label-backed)

    /// Gmail's storage model: messages live in `[Gmail]/All Mail` (a real
    /// mailbox, `source` NULL) and INBOX/Important/custom labels are VIEWS
    /// (`source` → All Mail) whose membership lives in `labels`. Nothing ever
    /// sets `messages.mailbox` to a label rowid, so a plain `m.mailbox IN (...)`
    /// matched zero rows and reported an empty inbox. Trash is a real mailbox
    /// even on Gmail — labels and real mailboxes coexist under one account.
    ///
    /// Layout: All Mail=10, INBOX=11, Important=12, Trash=13 (real).
    /// 401 labeled INBOX+Important, 402 labeled INBOX, 403 labeled Important
    /// only (archived — must NOT appear in INBOX), 404 in Trash, 405 in All
    /// Mail with no labels at all.
    private func makeGmailDB() throws -> DatabaseQueue {
        let q = try makeFixtureDB()
        try q.write { db in
            try db.execute(sql: """
            INSERT INTO mailboxes (ROWID, url, source) VALUES
              (10, 'imap://\(Self.uuidG)/%5BGmail%5D/All%20Mail', NULL),
              (11, 'imap://\(Self.uuidG)/INBOX', 10),
              (12, 'imap://\(Self.uuidG)/%5BGmail%5D/Important', 10),
              (13, 'imap://\(Self.uuidG)/%5BGmail%5D/Trash', NULL);

            INSERT INTO subjects (ROWID, subject) VALUES
              (11, 'Gmail inbox newest'),
              (12, 'Gmail inbox older'),
              (13, 'Gmail archived'),
              (14, 'Gmail trashed'),
              (15, 'Gmail unlabeled');

            INSERT INTO message_global_data (ROWID, message_id_header) VALUES
              (11, '<g-401@gmail.example.com>'),
              (12, '<g-402@gmail.example.com>'),
              (13, '<g-403@gmail.example.com>'),
              (14, '<g-404@gmail.example.com>'),
              (15, '<g-405@gmail.example.com>');

            INSERT INTO messages (ROWID, global_message_id, sender, subject, date_sent, date_received, mailbox, read, deleted, size) VALUES
              (401, 11, 1, 11, \(Self.jul10 + 9 * Self.hour), \(Self.jul10 + 9 * Self.hour), 10, 0, 0, 111),
              (402, 12, 2, 12, \(Self.jul10 + 8 * Self.hour), \(Self.jul10 + 8 * Self.hour), 10, 1, 0, 222),
              (403, 13, 2, 13, \(Self.jul10 + 7 * Self.hour), \(Self.jul10 + 7 * Self.hour), 10, 1, 0, 333),
              (404, 14, 2, 14, \(Self.jul10 + 6 * Self.hour), \(Self.jul10 + 6 * Self.hour), 13, 1, 0, 444),
              (405, 15, 2, 15, \(Self.jul10 + 5 * Self.hour), \(Self.jul10 + 5 * Self.hour), 10, 1, 0, 555);

            INSERT INTO labels (message_id, mailbox_id) VALUES
              (401, 11), (401, 12), (402, 11), (403, 12);
            """)
        }
        return q
    }

    private func makeGmailIndex() throws -> MailEnvelopeIndex {
        try MailEnvelopeIndex(
            dbQueue: makeGmailDB(),
            accounts: Self.accounts + [
                MailAccountRecord(name: "Gmail", email: "g@gmail.com", uuid: Self.uuidG),
            ]
        )
    }

    /// The regression: this returned [] with status ok, indistinguishable from
    /// an empty inbox, for every Gmail-family account.
    func testGmailInboxListsLabeledMessages() throws {
        let msgs = try makeGmailIndex().listMessages(
            account: "Gmail", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Gmail||INBOX||401", "Gmail||INBOX||402"])
        XCTAssertEqual(msgs[0].subject, "Gmail inbox newest")
        XCTAssertEqual(msgs[0].size, 111)
        XCTAssertFalse(msgs[0].read)
    }

    /// A label hit's backing row has `messages.mailbox` = All Mail, but the
    /// compound id and `mailbox` field must name what the caller asked for —
    /// `mail show`/`mark`/`move` round-trip on that id.
    func testGmailLabelHitNamesRequestedMailboxNotAllMail() throws {
        let msgs = try makeGmailIndex().listMessages(
            account: "Gmail", mailbox: "Important", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Gmail||Important||401", "Gmail||Important||403"])
        XCTAssertTrue(msgs.allSatisfy { $0.mailbox == "Important" })
        XCTAssertTrue(msgs.allSatisfy { $0.account == "Gmail" })
    }

    /// Archived mail (in All Mail, not labeled INBOX) must not leak into the
    /// inbox — the whole reason "just query All Mail" is not a fix.
    func testGmailArchivedAndUnlabeledExcludedFromInbox() throws {
        let ids = try makeGmailIndex().listMessages(
            account: "Gmail", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        ).map(\.id)
        XCTAssertFalse(ids.contains("Gmail||INBOX||403")) // archived, Important only
        XCTAssertFalse(ids.contains("Gmail||INBOX||405")) // no labels at all
        XCTAssertFalse(ids.contains("Gmail||INBOX||404")) // in Trash
    }

    /// Real mailboxes still work on a label-backed account.
    func testGmailRealMailboxStillMatchesOnMessageMailbox() throws {
        let msgs = try makeGmailIndex().listMessages(
            account: "Gmail", mailbox: "Trash", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Gmail||Trash||404"])
    }

    /// A cross-account INBOX scan mixes both storage models in one statement:
    /// Gmail contributed nothing before this fix, silently.
    func testCrossAccountInboxMixesLabelAndRealMailboxes() throws {
        let msgs = try makeGmailIndex().listMessages(
            account: nil, mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(msgs.map(\.id), [
            "Gmail||INBOX||401",
            "Gmail||INBOX||402",
            "Work||Inbox||201",
            "Personal||INBOX||101",
            "Personal||INBOX||102",
            "Personal||INBOX||105",
        ])
    }

    /// An empty label is a real "nothing here", not a resolution failure: the
    /// mailbox resolves, so the query answers [] rather than throwing to JXA.
    func testGmailEmptyLabelReturnsEmptyWithoutThrowing() throws {
        let q = try makeGmailDB()
        try q.write { db in
            try db.execute(sql: "DELETE FROM labels WHERE mailbox_id = 11")
        }
        let idx = try MailEnvelopeIndex(dbQueue: q, accounts: Self.accounts + [
            MailAccountRecord(name: "Gmail", email: "g@gmail.com", uuid: Self.uuidG),
        ])
        XCTAssertEqual(try idx.listMessages(
            account: "Gmail", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        ).map(\.id), [])
    }

    /// When a row matches both a real target and a label target (all-mailboxes
    /// scans), the real mailbox wins — keeps "no mailbox filter" naming All
    /// Mail exactly as it did before labels were handled.
    func testAllMailboxesScanPrefersRealMailboxOverLabel() throws {
        let msgs = try makeGmailIndex().searchMessages(
            query: "Gmail inbox newest", account: "Gmail", mailbox: nil,
            limit: 50, offset: 0, after: nil, before: nil, to: nil, from: nil
        )
        XCTAssertEqual(msgs.map(\.id), ["Gmail||All Mail||401"])
    }

    func testGmailLabelSearchAndActivity() throws {
        let idx = try makeGmailIndex()
        let hits = try idx.searchMessages(
            query: "inbox", account: "Gmail", mailbox: "INBOX",
            limit: 50, offset: 0, after: nil, before: nil, to: nil, from: nil
        )
        XCTAssertEqual(hits.map(\.id), ["Gmail||INBOX||401", "Gmail||INBOX||402"])

        let activity = try idx.listActivity(
            account: "Gmail", mailboxes: ["INBOX", "Trash"], since: nil, limit: 50
        )
        XCTAssertEqual(activity.map(\.id), [
            "Gmail||INBOX||401", "Gmail||INBOX||402", "Gmail||Trash||404",
        ])
    }

    func testGmailUnreadAndDateFiltersApplyToLabelMatches() throws {
        let idx = try makeGmailIndex()
        let unread = try idx.listMessages(
            account: "Gmail", mailbox: "INBOX", unread: true,
            limit: 50, offset: 0, after: nil, before: nil
        )
        XCTAssertEqual(unread.map(\.id), ["Gmail||INBOX||401"])

        let deleted = try makeGmailDB()
        try deleted.write { db in
            try db.execute(sql: "UPDATE messages SET deleted = 1 WHERE ROWID = 401")
        }
        let idx2 = try MailEnvelopeIndex(dbQueue: deleted, accounts: Self.accounts + [
            MailAccountRecord(name: "Gmail", email: "g@gmail.com", uuid: Self.uuidG),
        ])
        XCTAssertEqual(try idx2.listMessages(
            account: "Gmail", mailbox: "INBOX", unread: false,
            limit: 50, offset: 0, after: nil, before: nil
        ).map(\.id), ["Gmail||INBOX||402"])
    }
}
