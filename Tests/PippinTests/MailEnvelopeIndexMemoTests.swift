import Foundation
import GRDB
@testable import PippinLib
import XCTest

/// Snapshot reuse (PERF-4): one copy of the Envelope Index per process while
/// Mail's files are unchanged, and a fresh copy as soon as they change.
/// Hermetic: the "Mail" files are scratch files in a temp dir and the opener
/// is a counting fake over an in-memory database.
final class MailEnvelopeIndexMemoTests: XCTestCase {
    private var dir = ""
    private var dbPath = ""
    private let accounts = [MailAccountRecord(name: "Personal", email: "p@example.com", uuid: "A")]

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "pippin-memo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        dbPath = dir + "/Envelope Index"
        try Data("db".utf8).write(to: URL(fileURLWithPath: dbPath))
        try Data("wal".utf8).write(to: URL(fileURLWithPath: dbPath + "-wal"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.withLock { value += 1 }
        }

        var count: Int {
            lock.withLock { value }
        }
    }

    private func countingOpener(_ counter: Counter) -> MailEnvelopeIndexMemo.Opener {
        { _, accounts in
            counter.increment()
            let queue = try DatabaseQueue()
            try queue.write { db in
                try db.execute(sql: """
                CREATE TABLE properties (ROWID INTEGER PRIMARY KEY, key TEXT, value TEXT);
                INSERT INTO properties (key, value) VALUES ('version', '4');
                """)
            }
            return try MailEnvelopeIndex(dbQueue: queue, accounts: accounts)
        }
    }

    /// Rewrite a file with new content and a modification time that is
    /// certain to differ, without depending on the clock's resolution.
    private func change(_ path: String, to content: String, secondsAhead: TimeInterval) throws {
        try Data(content.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(secondsAhead)], ofItemAtPath: path
        )
    }

    func testUnchangedFilesOpenTheSnapshotOnce() throws {
        let memo = MailEnvelopeIndexMemo()
        let opens = Counter()
        let first = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        for _ in 0 ..< 5 {
            let again = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
            XCTAssertTrue(again === first)
        }
        XCTAssertEqual(opens.count, 1)
    }

    func testConcurrentCallersShareOneSnapshot() {
        let memo = MailEnvelopeIndexMemo()
        let opens = Counter()
        let open = countingOpener(opens)
        let dbPath = dbPath
        let accounts = accounts
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = try? memo.index(dbPath: dbPath, accounts: accounts, open: open)
        }
        XCTAssertEqual(opens.count, 1)
    }

    func testAWriteToTheWalForcesAFreshSnapshot() throws {
        let memo = MailEnvelopeIndexMemo()
        let opens = Counter()
        let first = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        try change(dbPath + "-wal", to: "wal plus a new message", secondsAhead: 5)
        let second = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        XCTAssertFalse(second === first)
        XCTAssertEqual(opens.count, 2)
    }

    func testASameSizeRewriteIsCaughtByModificationTime() throws {
        let memo = MailEnvelopeIndexMemo()
        let opens = Counter()
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        try change(dbPath + "-wal", to: "law", secondsAhead: 5) // same 3 bytes
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        XCTAssertEqual(opens.count, 2)
    }

    func testACheckpointForcesAFreshSnapshot() throws {
        let memo = MailEnvelopeIndexMemo()
        let opens = Counter()
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        // Mail checkpoints: the database is rewritten and the -wal goes away.
        try change(dbPath, to: "db after checkpoint", secondsAhead: 5)
        try FileManager.default.removeItem(atPath: dbPath + "-wal")
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        XCTAssertEqual(opens.count, 2)
    }

    func testAReplacedDatabaseFileForcesAFreshSnapshot() throws {
        let memo = MailEnvelopeIndexMemo()
        let opens = Counter()
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        // Same bytes and timestamp under a new inode, as an index rebuild leaves.
        let original = try FileManager.default.attributesOfItem(atPath: dbPath)[.modificationDate] as? Date
        try FileManager.default.moveItem(atPath: dbPath, toPath: dbPath + ".old")
        try Data("db".utf8).write(to: URL(fileURLWithPath: dbPath))
        try FileManager.default.setAttributes([.modificationDate: XCTUnwrap(original)], ofItemAtPath: dbPath)
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        XCTAssertEqual(opens.count, 2)
    }

    func testADifferentAccountMapForcesAFreshSnapshot() throws {
        let memo = MailEnvelopeIndexMemo()
        let opens = Counter()
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        let more = accounts + [MailAccountRecord(name: "Work", email: "w@example.com", uuid: "B")]
        _ = try memo.index(dbPath: dbPath, accounts: more, open: countingOpener(opens))
        XCTAssertEqual(opens.count, 2)
    }

    func testAFailedOpenIsNotRemembered() throws {
        let memo = MailEnvelopeIndexMemo()
        let opens = Counter()
        XCTAssertThrowsError(try memo.index(dbPath: dbPath, accounts: accounts) { path, _ in
            throw MailEnvelopeIndexError.accessDenied(path)
        })
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        XCTAssertEqual(opens.count, 1)
    }

    func testClearReleasesTheSnapshot() throws {
        let memo = MailEnvelopeIndexMemo()
        let opens = Counter()
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        memo.clear()
        _ = try memo.index(dbPath: dbPath, accounts: accounts, open: countingOpener(opens))
        XCTAssertEqual(opens.count, 2)
    }

    func testReadAheadAdviceIsAcceptedForAFileAndRefusedForAMissingOne() {
        XCTAssertTrue(MailEnvelopeIndex.adviseReadAhead(path: dbPath))
        XCTAssertFalse(MailEnvelopeIndex.adviseReadAhead(path: dir + "/absent"))
    }
}
