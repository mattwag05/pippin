@testable import PippinLib
import XCTest

/// The store's trust rules, with Mail replaced by closures.
final class MailMetaStoreTests: XCTestCase {
    private var store: MailMetaStore!
    private var path: String!
    private let inbox = MailboxKey(account: "A", mailbox: "INBOX")

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "mail-meta-\(UUID().uuidString).db"
        store = try MailMetaStore(dbPath: path)
    }

    override func tearDownWithError() throws {
        store = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func row(
        _ id: String, date: String = "2026-01-02T00:00:00.000Z", subject: String? = nil,
        rfc: String? = nil, attachment: Bool? = true, mailbox: String = "INBOX"
    ) -> MailMetaRow {
        MailMetaRow(
            compoundId: "A||\(mailbox)||\(id)", account: "A", mailbox: mailbox, rowId: id,
            dateSent: date, dateReceived: date, subject: subject ?? "s\(id)", sender: "from\(id)@x.y", size: 1,
            hasAttachment: attachment, rfcMessageId: rfc ?? "mid\(id)"
        )
    }

    private func live(_ ids: [String], dates: [String]? = nil, read: [Bool]? = nil, key: MailboxKey? = nil) -> MailLiveMailbox {
        let key = key ?? inbox
        return MailLiveMailbox(
            account: key.account, mailbox: key.mailbox, ids: ids,
            dates: dates ?? ids.map { _ in "2026-01-02T00:00:00.000Z" },
            read: read ?? ids.map { _ in false }
        )
    }

    private final class Calls: @unchecked Sendable {
        var refreshes = 0
        var facts: [[String]] = []
    }

    private func reader(
        live mailboxes: [MailLiveMailbox],
        fresh: [MailMetaRow] = [],
        facts: [String: MailLiveFacts] = [:],
        calls: Calls = Calls()
    ) -> MailMetaReader {
        MailMetaReader(
            store: store,
            volatile: { _ in mailboxes },
            refresh: { _ in
                calls.refreshes += 1
                return fresh
            },
            pageFacts: {
                calls.facts.append($0)
                return facts
            }
        )
    }

    private func distinctDated(_ ids: [String]) -> [String] {
        ids.indices.map { "2026-01-0\($0 + 1)T00:00:00.000Z" }
    }

    // MARK: - Scope

    func testScopeRequiresTheStoreToHoldTheMailbox() throws {
        XCTAssertNil(try reader(live: []).scope(account: "A", mailbox: "INBOX"))
        try store.replaceMailbox(inbox, rows: [])
        XCTAssertEqual(try reader(live: []).scope(account: "A", mailbox: "inbox"), [inbox])
        XCTAssertNil(try reader(live: []).scope(account: "A", mailbox: "Other"))
    }

    func testIncompleteMailboxIsNotAnswered() throws {
        try store.markIncomplete(inbox)
        XCTAssertNil(try reader(live: []).scope(account: "A", mailbox: "INBOX"))
        XCTAssertNil(try reader(live: []).scope(account: "A", mailbox: nil))
    }

    // MARK: - Trust rules

    func testReadStateComesFromTheLiveRead() throws {
        try store.replaceMailbox(inbox, rows: [row("1")])
        let unread = try XCTUnwrap(reader(live: [live(["1"], read: [false])])
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true })
        XCTAssertEqual(unread.first?.read, false)
        let read = try XCTUnwrap(reader(live: [live(["1"], read: [true])])
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true })
        XCTAssertEqual(read.first?.read, true)
    }

    func testReassignedIdNeverReturnsTheOldRow() throws {
        try store.replaceMailbox(inbox, rows: [row("1", date: "2026-01-01T00:00:00.000Z", subject: "old")])
        let new = row("1", date: "2026-02-02T00:00:00.000Z", subject: "new")
        let calls = Calls()
        let result = try XCTUnwrap(reader(live: [live(["1"], dates: ["2026-02-02T00:00:00.000Z"])], fresh: [new], calls: calls)
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true })
        XCTAssertEqual(result.map(\.subject), ["new"])
        XCTAssertEqual(calls.refreshes, 1)
        XCTAssertEqual(try store.rows(in: inbox).map(\.subject), ["new"], "written through")
    }

    func testIdStillDisagreeingAfterRefreshIsAMiss() throws {
        try store.replaceMailbox(inbox, rows: [row("1", date: "2026-01-01T00:00:00.000Z")])
        let result = try reader(live: [live(["1"], dates: ["2026-02-02T00:00:00.000Z"])], fresh: [])
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true }
        XCTAssertNil(result)
    }

    func testNewMessageIsReadLiveAndWrittenThrough() throws {
        try store.replaceMailbox(inbox, rows: [row("1")])
        let calls = Calls()
        let result = try XCTUnwrap(reader(live: [live(["1", "2"])], fresh: [row("1"), row("2")], facts: factsFor(["1", "2"]), calls: calls)
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true })
        XCTAssertEqual(Set(result.map(\.id)), ["A||INBOX||1", "A||INBOX||2"])
        XCTAssertEqual(calls.refreshes, 1)
        XCTAssertEqual(try store.rows(in: inbox).count, 2)
    }

    private func factsFor(_ ids: [String]) -> [String: MailLiveFacts] {
        Dictionary(uniqueKeysWithValues: ids.map {
            ("A||INBOX||\($0)", MailLiveFacts(hasAttachment: false, messageId: "mid\($0)", dateSent: nil))
        })
    }

    func testDeletedMessageDisappears() throws {
        let ids = ["1", "2"]
        try store.replaceMailbox(inbox, rows: zip(ids, distinctDated(ids)).map { row($0, date: $1) })
        let result = try XCTUnwrap(reader(live: [live(["2"], dates: [distinctDated(ids)[1]])])
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true })
        XCTAssertEqual(result.map(\.id), ["A||INBOX||2"])
    }

    func testDateCollisionWithMatchingMessageIdPasses() throws {
        try store.replaceMailbox(inbox, rows: [row("1"), row("2")])
        let calls = Calls()
        let result = try XCTUnwrap(reader(live: [live(["1", "2"])], facts: factsFor(["1", "2"]), calls: calls)
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true })
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(calls.refreshes, 0)
    }

    func testDateCollisionWithChangedMessageIdRefreshes() throws {
        try store.replaceMailbox(inbox, rows: [row("1", subject: "old"), row("2")])
        var facts = factsFor(["1", "2"])
        facts["A||INBOX||1"] = MailLiveFacts(hasAttachment: false, messageId: "different", dateSent: nil)
        let calls = Calls()
        let replacement = [row("1", subject: "new", rfc: "different"), row("2")]
        let fresh = MailMetaReader(
            store: store,
            volatile: { _ in [self.live(["1", "2"])] },
            refresh: { _ in
                calls.refreshes += 1
                return replacement
            },
            pageFacts: { _ in calls.refreshes == 0 ? facts : facts }
        )
        let result = try XCTUnwrap(fresh.answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true })
        XCTAssertEqual(calls.refreshes, 1)
        XCTAssertTrue(result.contains { $0.subject == "new" })
        XCTAssertFalse(result.contains { $0.subject == "old" })
    }

    func testUnresolvableCollisionIsAMiss() throws {
        try store.replaceMailbox(inbox, rows: [row("1"), row("2")])
        let result = try reader(live: [live(["1", "2"])], facts: [:])
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true }
        XCTAssertNil(result)
    }

    func testMissingLiveMailboxIsAMiss() throws {
        try store.replaceMailbox(inbox, rows: [row("1")])
        XCTAssertNil(try reader(live: []).answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true })
    }

    // MARK: - Shape

    func testIdsMatchTheSlowPathAndPageNewestFirst() throws {
        let ids = ["1", "2", "3"]
        let dates = distinctDated(ids)
        try store.replaceMailbox(inbox, rows: zip(ids, dates).map { row($0, date: $1) })
        let result = try XCTUnwrap(reader(live: [live(ids, dates: dates)]).answer(scope: [inbox], limit: 1, offset: 1) { _, _ in true })
        XCTAssertEqual(result.map(\.id), ["A||INBOX||2"])
    }

    func testDuplicateAcrossMailboxesIsDeduped() throws {
        let allMail = MailboxKey(account: "A", mailbox: "All Mail")
        try store.replaceMailbox(inbox, rows: [row("1", rfc: "same")])
        try store.replaceMailbox(allMail, rows: [row("9", date: "2026-01-02T00:00:00.000Z", rfc: "same", mailbox: "All Mail")])
        let result = try XCTUnwrap(reader(live: [live(["1"]), live(["9"], key: allMail)])
            .answer(scope: [inbox, allMail], limit: 10, offset: 0) { _, _ in true })
        XCTAssertEqual(result.count, 1)
    }

    func testAttachmentFlagIsFetchedOnceAndSurvivesRefresh() throws {
        try store.replaceMailbox(inbox, rows: [row("1", attachment: nil)])
        let calls = Calls()
        let facts = ["A||INBOX||1": MailLiveFacts(hasAttachment: true, messageId: "mid1", dateSent: nil)]
        let first = try XCTUnwrap(reader(live: [live(["1"])], facts: facts, calls: calls)
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true })
        XCTAssertEqual(first.first?.hasAttachment, true)
        XCTAssertEqual(calls.facts.count, 1)
        _ = try reader(live: [live(["1"])], facts: facts, calls: calls)
            .answer(scope: [inbox], limit: 10, offset: 0) { _, _ in true }
        XCTAssertEqual(calls.facts.count, 1, "known flag is not read again")
        try store.replaceMailbox(inbox, rows: [row("1", attachment: nil)])
        XCTAssertEqual(try store.rows(in: inbox).first?.hasAttachment, true)
    }

    func testFilterSeesLiveReadState() throws {
        try store.replaceMailbox(inbox, rows: [row("1")])
        let result = try XCTUnwrap(reader(live: [live(["1"], read: [true])])
            .answer(scope: [inbox], limit: 10, offset: 0) { _, read in !read })
        XCTAssertTrue(result.isEmpty)
    }

    func testFillInProgressCarriesANextCall() {
        XCTAssertEqual(MailBridgeError.fillInProgress.agentCode, "fill_in_progress")
        XCTAssertEqual(MailBridgeError.fillInProgress.nextStep.nextCall?.tool, "job_list")
        XCTAssertFalse(MailBridgeError.fillInProgress.nextStep.retryable)
    }
}
