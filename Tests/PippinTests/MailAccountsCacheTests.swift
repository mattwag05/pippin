import Foundation
@testable import PippinLib
import XCTest

/// Tests for the on-disk Mail account name→UUID cache that feeds the Envelope
/// Index fast path (pippin-60x). All file I/O goes to a temp path; the JXA
/// fetch is an injected closure (CI-safe).
final class MailAccountsCacheTests: XCTestCase {
    private var path = ""

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "mail-accounts-test-\(UUID().uuidString).json"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    private let sample = [
        MailAccountRecord(name: "Personal", email: "p@example.com", uuid: "AAAA-1111"),
        MailAccountRecord(name: "Work", email: "w@example.com", uuid: "BBBB-2222"),
    ]

    // MARK: - Load/save

    func testLoadMissingFileReturnsEmpty() {
        let (accounts, fetchedAt) = MailAccountsCache.load(path: path)
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertNil(fetchedAt)
    }

    func testSaveLoadRoundtrip() {
        let stamp = Date(timeIntervalSince1970: 1_784_000_000)
        MailAccountsCache.save(sample, fetchedAt: stamp, path: path)
        let (accounts, fetchedAt) = MailAccountsCache.load(path: path)
        XCTAssertEqual(accounts, sample)
        XCTAssertEqual(fetchedAt.map { Int($0.timeIntervalSince1970) }, 1_784_000_000)
    }

    func testLoadCorruptFileReturnsEmpty() throws {
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        let (accounts, _) = MailAccountsCache.load(path: path)
        XCTAssertTrue(accounts.isEmpty)
    }

    // MARK: - ensure()

    func testEnsureFetchesWhenCacheEmpty() throws {
        var fetchCount = 0
        let result = try MailAccountsCache.ensure(accountName: nil, path: path) {
            fetchCount += 1
            return self.sample
        }
        XCTAssertEqual(result, sample)
        XCTAssertEqual(fetchCount, 1)
        // and persists for the next call
        let (cached, _) = MailAccountsCache.load(path: path)
        XCTAssertEqual(cached, sample)
    }

    func testEnsureUsesCacheWithoutFetching() throws {
        MailAccountsCache.save(sample, fetchedAt: Date(), path: path)
        var fetchCount = 0
        let result = try MailAccountsCache.ensure(accountName: "Work", path: path) {
            fetchCount += 1
            return []
        }
        XCTAssertEqual(result, sample)
        XCTAssertEqual(fetchCount, 0)
    }

    func testEnsureRefreshesOnAccountNameMiss() throws {
        MailAccountsCache.save([sample[0]], fetchedAt: Date(), path: path)
        var fetchCount = 0
        let result = try MailAccountsCache.ensure(accountName: "Work", path: path) {
            fetchCount += 1
            return self.sample
        }
        XCTAssertEqual(result, sample)
        XCTAssertEqual(fetchCount, 1)
    }

    func testEnsureThrowsWhenEmptyAndFetchFails() {
        struct Boom: Error {}
        XCTAssertThrowsError(try MailAccountsCache.ensure(accountName: nil, path: path) {
            throw Boom()
        }) { error in
            guard case MailEnvelopeIndexError.accountsUnavailable = error else {
                XCTFail("Expected accountsUnavailable, got \(error)"); return
            }
        }
    }

    func testEnsureFallsBackToCacheWhenFetchFails() throws {
        // Name-miss triggers a refresh; refresh fails; the stale cache is still
        // returned (the caller's resolution will throw accountUnknown → JXA).
        MailAccountsCache.save([sample[0]], fetchedAt: Date(), path: path)
        struct Boom: Error {}
        let result = try MailAccountsCache.ensure(accountName: "Work", path: path) {
            throw Boom()
        }
        XCTAssertEqual(result, [sample[0]])
    }

    // MARK: - Staleness (unknown-UUID self-heal TTL)

    func testIsStale() {
        let now = Date()
        XCTAssertTrue(MailAccountsCache.isStale(fetchedAt: nil, now: now))
        XCTAssertTrue(MailAccountsCache.isStale(fetchedAt: now.addingTimeInterval(-7200), now: now))
        XCTAssertFalse(MailAccountsCache.isStale(fetchedAt: now.addingTimeInterval(-60), now: now))
    }
}
