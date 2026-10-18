@testable import PippinLib
import XCTest

/// Unit tests for the mail body cache. Uses a temp-file DB so they run without
/// Mail.app access (CI-safe).
final class MailBodyCacheTests: XCTestCase {
    private var dbPath: String!
    private var cache: MailBodyCache!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "mail-cache-test-\(UUID().uuidString).db"
        cache = try MailBodyCache(dbPath: dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func makeMessage(id: String, body: String = "Hello body", date: String = "2026-06-03T12:00:00Z") -> MailMessage {
        MailMessage(
            id: id, account: "iCloud", mailbox: "INBOX",
            subject: "Subj", from: "a@b.com", to: ["c@d.com"],
            date: date, read: false, body: body,
            htmlBody: "<p>\(body)</p>", headers: ["X-Test": "1"]
        )
    }

    func testPutThenGetRoundTrips() {
        let msg = makeMessage(id: "iCloud||INBOX||1", body: "cached content")
        XCTAssertNil(cache.get(compoundId: "iCloud||INBOX||1", expectedDate: "2026-06-03T12:00:00Z"))
        cache.put(msg)
        let fetched = cache.get(compoundId: "iCloud||INBOX||1", expectedDate: "2026-06-03T12:00:00Z")
        XCTAssertEqual(fetched?.id, msg.id)
        XCTAssertEqual(fetched?.body, "cached content")
        XCTAssertEqual(fetched?.htmlBody, "<p>cached content</p>")
        XCTAssertEqual(fetched?.headers?["X-Test"], "1")
    }

    func testMissReturnsNil() {
        XCTAssertNil(cache.get(compoundId: "nope||INBOX||999", expectedDate: "2026-06-03T12:00:00Z"))
    }

    func testPutIsUpsert() {
        cache.put(makeMessage(id: "id1", body: "v1"))
        cache.put(makeMessage(id: "id1", body: "v2"))
        XCTAssertEqual(cache.count(), 1)
        XCTAssertEqual(cache.get(compoundId: "id1", expectedDate: "2026-06-03T12:00:00Z")?.body, "v2")
    }

    func testCountAndClear() {
        cache.put(makeMessage(id: "a"))
        cache.put(makeMessage(id: "b"))
        XCTAssertEqual(cache.count(), 2)
        XCTAssertEqual(cache.clear(), 2)
        XCTAssertEqual(cache.count(), 0)
    }

    func testStatsReportsCountAndRange() throws {
        cache.put(makeMessage(id: "a"), at: Date(timeIntervalSince1970: 1_000_000))
        cache.put(makeMessage(id: "b"), at: Date(timeIntervalSince1970: 2_000_000))
        let stats = cache.stats()
        XCTAssertEqual(stats.count, 2)
        let oldest = try XCTUnwrap(stats.oldest)
        let newest = try XCTUnwrap(stats.newest)
        XCTAssertLessThan(oldest, newest)
    }

    func testPruneDeletesOldEntries() {
        cache.put(makeMessage(id: "old"), at: Date(timeIntervalSince1970: 1_000_000))
        cache.put(makeMessage(id: "new"), at: Date())
        let cutoff = Date(timeIntervalSince1970: 1_500_000)
        XCTAssertEqual(cache.prune(olderThan: cutoff), 1)
        XCTAssertNil(cache.get(compoundId: "old", expectedDate: "2026-06-03T12:00:00Z"))
        XCTAssertNotNil(cache.get(compoundId: "new", expectedDate: "2026-06-03T12:00:00Z"))
    }

    // MARK: - Identity validation (pippin-pvak)

    /// Mail reassigns a compound id's ROWID to a different message (index
    /// rebuild or ROWID reuse). The cached body of the OLD message must not be
    /// served for the new one, and the stale row must be evicted.
    func testGetRejectsAndEvictsEntryForADifferentMessage() {
        cache.put(makeMessage(id: "iCloud||INBOX||29556", body: "July CI failure", date: "2026-07-29T15:32:20.000Z"))
        XCTAssertNil(cache.get(compoundId: "iCloud||INBOX||29556", expectedDate: "2026-10-18T17:27:25.000Z"))
        XCTAssertEqual(cache.count(), 0, "stale row evicted")
    }

    func testGetAcceptsSameInstantInEitherISOForm() {
        cache.put(makeMessage(id: "a", date: "2026-07-29T15:32:20.000Z"))
        XCTAssertNotNil(cache.get(compoundId: "a", expectedDate: "2026-07-29T15:32:20Z"))
        XCTAssertNotNil(cache.get(compoundId: "a", expectedDate: "2026-07-29T15:32:20.000Z"))
    }

    func testGetManyServesOnlyMatchingIdentities() {
        cache.put(makeMessage(id: "fresh", body: "right", date: "2026-10-18T10:00:00.000Z"))
        cache.put(makeMessage(id: "stale", body: "wrong", date: "2026-06-20T14:12:19.000Z"))
        cache.put(makeMessage(id: "unchecked", body: "unknown", date: "2026-06-20T14:12:19.000Z"))
        let hits = cache.getMany(expectedDates: [
            "fresh": "2026-10-18T10:00:00.000Z",
            "stale": "2026-10-18T17:15:17.000Z",
        ])
        XCTAssertEqual(hits.mapValues(\.body), ["fresh": "right"])
        XCTAssertEqual(cache.count(), 2, "only the mismatched row is evicted; an id with no expected identity is left alone")
    }
}
