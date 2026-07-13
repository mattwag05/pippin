import Contacts
@testable import PippinLib
import XCTest

/// Unit tests for the persisted contact-resolution index. Uses a temp-file DB
/// and synthetic tokens so they run without a real `CNContactStore` (CI-safe).
final class ContactIndexCacheTests: XCTestCase {
    private var dbPath: String!
    private var cache: ContactIndexCache!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "contact-index-test-\(UUID().uuidString).db"
        cache = try ContactIndexCache(dbPath: dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func makeIndex() -> ContactIndex {
        var index = ContactIndex()
        index.add(name: "Alice Smith", phones: ["+1 (513) 267-1812"], emails: ["Alice@Example.com"])
        index.add(name: "Bob Jones", phones: [], emails: ["bob@example.com"])
        return index
    }

    func testEmptyCacheIsMiss() {
        XCTAssertNil(cache.load(matching: Data("t1".utf8)))
    }

    func testStoreThenLoadRoundTrips() throws {
        let token = Data("t1".utf8)
        cache.store(makeIndex(), token: token)
        let loaded = try XCTUnwrap(cache.load(matching: token))
        // Lowercased email keys survive.
        XCTAssertEqual(loaded.displayName(for: "alice@example.com"), "Alice Smith")
        XCTAssertEqual(loaded.displayName(for: "ALICE@EXAMPLE.COM"), "Alice Smith")
        XCTAssertEqual(loaded.displayName(for: "bob@example.com"), "Bob Jones")
        // Both phone keys (full digits + last-10 fallback) survive.
        XCTAssertEqual(loaded.displayName(for: "+15132671812"), "Alice Smith")
        XCTAssertEqual(loaded.displayName(for: "5132671812"), "Alice Smith")
        XCTAssertNil(loaded.displayName(for: "unknown@example.com"))
    }

    func testFirstWriteWinsSurvivesRoundTrip() throws {
        var index = ContactIndex()
        index.add(name: "Alice", phones: [], emails: ["shared@example.com"])
        index.add(name: "Bob", phones: [], emails: ["shared@example.com"])
        let token = Data("t1".utf8)
        cache.store(index, token: token)
        let loaded = try XCTUnwrap(cache.load(matching: token))
        XCTAssertEqual(loaded.displayName(for: "shared@example.com"), "Alice")
    }

    func testTokenMismatchIsMiss() {
        cache.store(makeIndex(), token: Data("t1".utf8))
        XCTAssertNil(cache.load(matching: Data("t2".utf8)))
    }

    func testStoreReplacesPreviousContents() throws {
        cache.store(makeIndex(), token: Data("t1".utf8))
        var fresh = ContactIndex()
        fresh.add(name: "Carol", phones: [], emails: ["carol@example.com"])
        cache.store(fresh, token: Data("t2".utf8))
        XCTAssertNil(cache.load(matching: Data("t1".utf8)))
        let loaded = try XCTUnwrap(cache.load(matching: Data("t2".utf8)))
        XCTAssertEqual(loaded.displayName(for: "carol@example.com"), "Carol")
        XCTAssertNil(loaded.displayName(for: "alice@example.com")) // stale rows gone
    }

    func testEmptyCompleteIndexRoundTrips() throws {
        // An empty-but-complete enumeration is a valid cacheable state.
        let token = Data("t1".utf8)
        cache.store(ContactIndex(), token: token)
        let loaded = try XCTUnwrap(cache.load(matching: token))
        XCTAssertTrue(loaded.isEmpty)
    }

    func testPersistIfCompleteSkipsTimedOutIndex() {
        // A soft-timeout hit means the enumeration is partial — caching it
        // would freeze incomplete data behind a current token.
        ContactsBridge.persistIfComplete(makeIndex(), timedOut: true, token: Data("t1".utf8), to: cache)
        XCTAssertNil(cache.load(matching: Data("t1".utf8)))
    }

    func testPersistIfCompleteWritesCompleteIndex() throws {
        let token = Data("t1".utf8)
        ContactsBridge.persistIfComplete(makeIndex(), timedOut: false, token: token, to: cache)
        let loaded = try XCTUnwrap(cache.load(matching: token))
        XCTAssertEqual(loaded.displayName(for: "bob@example.com"), "Bob Jones")
    }

    func testPersistIfCompleteSkipsNilToken() {
        ContactsBridge.persistIfComplete(makeIndex(), timedOut: false, token: nil, to: cache)
        XCTAssertNil(cache.load(matching: Data("t1".utf8)))
    }

    func testCorruptDbFailsOpenSilently() throws {
        let path = NSTemporaryDirectory() + "contact-index-corrupt-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data("this is not a sqlite database, not even close".utf8)
            .write(to: URL(fileURLWithPath: path))
        // Open fails → callers get nil (like `shared`) and fall back to live
        // enumeration; no crash, no throw escaping.
        XCTAssertNil(try? ContactIndexCache(dbPath: path))
    }
}
