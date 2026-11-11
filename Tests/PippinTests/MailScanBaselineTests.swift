import Foundation
import GRDB
@testable import PippinLib
import XCTest

/// pippin-09ky: the Envelope Index scan harvests msgid_domain fingerprints
/// into the sender baseline. Synthetic fixtures only.
final class MailScanBaselineTests: XCTestCase {
    private let uuid = "AAAAAAAA-1111-1111-1111-111111111111"
    private var storePath: String!
    private var store: SenderBaselineStore!

    override func setUpWithError() throws {
        storePath = NSTemporaryDirectory() + "pippin-test-scanbase-\(UUID().uuidString).db"
        store = try SenderBaselineStore(dbPath: storePath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: storePath)
    }

    /// Four INBOX messages from ci@example.com; `domains[i]` is message i+1's Message-ID domain.
    private func makeIndex(domains: [String], useStore: Bool = true) throws -> MailEnvelopeIndex {
        let q = try DatabaseQueue()
        try q.write { db in
            try db.execute(sql: """
            CREATE TABLE properties (ROWID INTEGER PRIMARY KEY, key TEXT, value TEXT);
            CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT NOT NULL, source INTEGER);
            CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
            CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
            CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT);
            CREATE TABLE messages (
                ROWID INTEGER PRIMARY KEY, global_message_id INTEGER NOT NULL DEFAULT 0, sender INTEGER,
                subject INTEGER NOT NULL, date_sent INTEGER, date_received INTEGER, mailbox INTEGER NOT NULL,
                read INTEGER NOT NULL DEFAULT 0, flagged INTEGER NOT NULL DEFAULT 0,
                deleted INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER NOT NULL,
                address INTEGER NOT NULL, type INTEGER, position INTEGER);
            CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INTEGER NOT NULL, name TEXT);
            CREATE TABLE labels (message_id INTEGER, mailbox_id INTEGER,
                PRIMARY KEY(message_id, mailbox_id)) WITHOUT ROWID;
            INSERT INTO properties (key, value) VALUES ('version', '4');
            INSERT INTO mailboxes (ROWID, url) VALUES (1, 'imap://\(uuid)/INBOX');
            INSERT INTO subjects (ROWID, subject) VALUES (1, 'Build');
            INSERT INTO addresses (ROWID, address, comment) VALUES (1, 'ci@example.com', 'CI');
            """)
            for (i, d) in domains.enumerated() {
                let n = i + 1
                try db.execute(sql: """
                INSERT INTO message_global_data (ROWID, message_id_header) VALUES (\(n), '<m\(n)@\(d)>');
                INSERT INTO messages (ROWID, global_message_id, sender, subject, date_sent, date_received, mailbox, size)
                VALUES (\(n), \(n), 1, 1, \(1_783_987_200 + n * 60), \(1_783_987_200 + n * 60), 1, 100);
                """)
            }
        }
        return try MailEnvelopeIndex(
            dbQueue: q, accounts: [MailAccountRecord(name: "Personal", email: "p@example.com", uuid: uuid)],
            baselineStore: useStore ? store : nil
        )
    }

    private func scan(_ idx: MailEnvelopeIndex) throws -> [MailMessage] {
        try idx.listMessages(account: nil, mailbox: "INBOX", unread: false, limit: 50, offset: 0, after: nil, before: nil)
    }

    private func msgidRows() throws -> [String: String] {
        let q = try DatabaseQueue(path: storePath)
        return try q.read { db in
            var out: [String: String] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT compound_id, value, dimension FROM fingerprints") {
                XCTAssertEqual(r["dimension"] as String, "msgid_domain", "scan must record only msgid_domain")
                out[r["compound_id"]] = r["value"]
            }
            return out
        }
    }

    func testScanWritesMsgidDomainRows() throws {
        let rows = try scan(makeIndex(domains: ["a.example", "a.example"]))
        XCTAssertEqual(rows.count, 2)
        let stored = try msgidRows()
        XCTAssertEqual(stored.count, 2)
        for m in rows { XCTAssertEqual(stored[m.id], "a.example") }
    }

    func testSecondScanWritesNothingNew() throws {
        let idx = try makeIndex(domains: ["a.example", "a.example"])
        _ = try scan(idx)
        let q = try DatabaseQueue(path: storePath)
        try q.write { try $0.execute(sql: "UPDATE fingerprints SET value = 'sentinel'") }
        _ = try scan(idx)
        XCTAssertEqual(Set(try msgidRows().values), ["sentinel"], "repeat scan must not rewrite rows")
        XCTAssertEqual(try msgidRows().count, 2)
    }

    func testFullReadRowIsNotOverwritten() throws {
        let idx = try makeIndex(domains: ["a.example"])
        let id = "Personal||INBOX||1"
        store.checkAndRecord(compoundId: id, sender: "ci@example.com", fingerprint: ["msgid_domain": "fullread.example", "tz_offset": "-0400"])
        _ = try scan(idx)
        let q = try DatabaseQueue(path: storePath)
        let v = try q.read { try String.fetchOne($0, sql: "SELECT value FROM fingerprints WHERE compound_id = ? AND dimension = 'msgid_domain'", arguments: [id]) }
        XCTAssertEqual(v, "fullread.example")
    }

    func testScanHarvestFeedsDeviationFlagForNeverShownMessage() throws {
        // Messages 1-3 share a domain (baseline); message 4 deviates.
        let rows = try scan(makeIndex(domains: ["ci.example", "ci.example", "ci.example", "evil.example"]))
        let cache = try MailBodyCache(dbPath: NSTemporaryDirectory() + "pippin-test-scancache-\(UUID().uuidString).db")
        // attachCachedAnomalies needs cached headers for the row under test.
        let target = try XCTUnwrap(rows.first { $0.messageIdHeader?.hasSuffix("evil.example") == true })
        cache.put(MailMessage(
            id: target.id, account: target.account, mailbox: target.mailbox, subject: target.subject,
            from: target.from, to: ["p@example.com"], date: target.date, read: false, body: "x",
            headers: ["Message-Id": "<m4@evil.example>", "To": "p@example.com"]
        ))
        let out = MailBridge.attachCachedAnomalies(rows, cache: cache, store: store)
        let flagged = try XCTUnwrap(out.first { $0.id == target.id }?.headerAnomalies)
        XCTAssertTrue(flagged.contains { $0.contains("Message-ID domain") }, "\(flagged)")
    }

    func testStoreFailureLeavesScanResultIdentical() throws {
        let idx = try makeIndex(domains: ["a.example", "a.example"])
        let q = try DatabaseQueue(path: storePath)
        try q.write { try $0.execute(sql: "DROP TABLE fingerprints") }
        XCTAssertFalse(store.recordScanFingerprints([("x", "a@b.com", "b.com")]))
        let broken = try scan(idx)
        let plain = try scan(makeIndex(domains: ["a.example", "a.example"], useStore: false))
        XCTAssertEqual(broken.map(\.id), plain.map(\.id))
        XCTAssertEqual(broken.map(\.messageIdHeader), plain.map(\.messageIdHeader))
    }
}
