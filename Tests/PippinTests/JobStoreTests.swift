@testable import PippinLib
import XCTest

final class JobStoreTests: XCTestCase {
    var tempRoot: String!
    var store: JobStore!

    override func setUp() {
        super.setUp()
        tempRoot = NSTemporaryDirectory() + "pippin-jobs-test-\(UUID().uuidString)"
        store = JobStore(root: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempRoot)
        super.tearDown()
    }

    // MARK: - Round-trip

    func testWriteReadRoundTrip() throws {
        let id = JobId.generate()
        try store.createDir(id)
        let job = Job(
            id: id,
            argv: ["mail", "list"],
            pid: 42,
            status: .running,
            startedAt: Date()
        )
        try store.write(job)
        let loaded = try store.read(id)
        XCTAssertEqual(loaded.id, job.id)
        XCTAssertEqual(loaded.argv, job.argv)
        XCTAssertEqual(loaded.pid, 42)
        XCTAssertEqual(loaded.status, .running)
    }

    func testTerminalStateEncoding() throws {
        let id = JobId.generate()
        try store.createDir(id)
        let now = Date()
        let job = Job(
            id: id,
            argv: ["doctor"],
            pid: 7,
            status: .done,
            exitCode: 0,
            startedAt: now.addingTimeInterval(-2),
            endedAt: now
        )
        try store.write(job)
        let loaded = try store.read(id)
        XCTAssertEqual(loaded.status, .done)
        XCTAssertEqual(loaded.exitCode, 0)
        XCTAssertEqual(loaded.durationMs, 2000)
        XCTAssertNotNil(loaded.endedAt)
    }

    // MARK: - Prefix resolution

    func testResolveFullId() throws {
        let id = "abc123def456"
        try FileManager.default.createDirectory(atPath: tempRoot + "/\(id)", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tempRoot + "/\(id)/status.json", contents: Data("{}".utf8))
        XCTAssertEqual(try store.resolve(id), id)
    }

    func testResolvePrefix() throws {
        let id = "abcdef123456"
        try FileManager.default.createDirectory(atPath: tempRoot + "/\(id)", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tempRoot + "/\(id)/status.json", contents: Data("{}".utf8))
        XCTAssertEqual(try store.resolve("abc"), id)
    }

    func testResolveAmbiguousPrefixThrows() throws {
        let a = "abc111111111"
        let b = "abc222222222"
        for id in [a, b] {
            try FileManager.default.createDirectory(atPath: tempRoot + "/\(id)", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: tempRoot + "/\(id)/status.json", contents: Data("{}".utf8))
        }
        XCTAssertThrowsError(try store.resolve("abc")) { error in
            guard case let JobStoreError.ambiguousPrefix(_, matches) = error else {
                XCTFail("Expected ambiguousPrefix, got \(error)")
                return
            }
            XCTAssertEqual(matches.sorted(), [a, b])
        }
    }

    func testResolveUnknownThrowsNotFound() {
        XCTAssertThrowsError(try store.resolve("nope")) { error in
            guard case JobStoreError.jobNotFound = error else {
                XCTFail("Expected jobNotFound, got \(error)")
                return
            }
        }
    }

    // MARK: - Listing

    func testListIdsSortedChronologically() throws {
        let ids = [JobId.generate(), JobId.generate(), JobId.generate()]
        for id in ids {
            try store.createDir(id)
            try store.write(Job(id: id, argv: ["x"]))
        }
        let listed = store.listIds()
        // IDs are millisecond-prefixed hex, ascending sort = chronological.
        XCTAssertEqual(listed, ids.sorted())
    }

    func testAllSkipsMalformedStatus() throws {
        let good = JobId.generate()
        try store.createDir(good)
        try store.write(Job(id: good, argv: ["y"]))
        let bad = JobId.generate()
        try store.createDir(bad)
        FileManager.default.createFile(
            atPath: store.statusPath(bad),
            contents: Data("not-json".utf8)
        )
        let all = store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, good)
    }

    // MARK: - GC

    func testGcRemovesOldTerminalJobs() throws {
        let id = JobId.generate()
        try store.createDir(id)
        let ended = Date().addingTimeInterval(-10 * 86400) // 10 days ago
        try store.write(Job(
            id: id,
            argv: ["x"],
            status: .done,
            exitCode: 0,
            startedAt: ended.addingTimeInterval(-1),
            endedAt: ended
        ))
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let removed = try store.gc(olderThan: cutoff)
        XCTAssertEqual(removed, [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.jobDir(id)))
    }

    func testGcPreservesRunningJobs() throws {
        let id = JobId.generate()
        try store.createDir(id)
        try store.write(Job(
            id: id,
            argv: ["x"],
            status: .running,
            startedAt: Date().addingTimeInterval(-30 * 86400) // 30 days old
        ))
        let removed = try store.gc(olderThan: Date())
        XCTAssertEqual(removed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.jobDir(id)))
    }

    func testGcPreservesRecentTerminalJobs() throws {
        let id = JobId.generate()
        try store.createDir(id)
        let ended = Date().addingTimeInterval(-1 * 3600) // 1 hour ago
        try store.write(Job(
            id: id,
            argv: ["x"],
            status: .done,
            exitCode: 0,
            startedAt: ended.addingTimeInterval(-1),
            endedAt: ended
        ))
        let cutoff = Date().addingTimeInterval(-86400) // 1 day cutoff
        let removed = try store.gc(olderThan: cutoff)
        XCTAssertEqual(removed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.jobDir(id)))
    }

    // MARK: - Log tails

    func testTailReturnsLastNBytes() throws {
        let id = JobId.generate()
        try store.createDir(id)
        let payload = String(repeating: "x", count: 1000) + "END"
        try payload.data(using: .utf8)?.write(to: URL(fileURLWithPath: store.stdoutPath(id)))
        let tail = store.tailStdout(id, maxBytes: 10)
        XCTAssertEqual(tail.count, 10)
        XCTAssertTrue(tail.hasSuffix("END"))
    }

    func testTailEmptyFileReturnsEmpty() throws {
        let id = JobId.generate()
        try store.createDir(id)
        XCTAssertEqual(store.tailStdout(id), "")
    }

    // MARK: - JobId uniqueness

    func testJobIdGeneratesUniqueValues() {
        // JobId = 11-hex millisecond-timestamp prefix + 5-hex (20-bit) random
        // suffix. Real job spawns are always >1ms apart, so the timestamp prefix
        // guarantees uniqueness; within a single millisecond uniqueness rides on
        // the 20-bit suffix (collision ~1-in-1M per pair, by design — see JobId).
        // Space generations past the 1ms boundary so this asserts the real
        // guarantee instead of flaking on the rare same-ms suffix birthday
        // collision (100 same-ms IDs collide ~0.5% of runs — see pippin-84q).
        var ids: [String] = []
        for _ in 0 ..< 50 {
            ids.append(JobId.generate())
            Thread.sleep(forTimeInterval: 0.0012)
        }
        XCTAssertEqual(Set(ids).count, ids.count, "IDs generated >1ms apart must all be unique")

        // Guard against a constant-suffix regression (the spacing alone would
        // still pass on distinct timestamps). Only fails if all 50 random
        // 20-bit draws are identical — probability ~0.
        let suffixes = Set(ids.map { String($0.suffix(5)) })
        XCTAssertGreaterThan(suffixes.count, 1, "random suffix should vary across IDs")
    }

    func testJobIdIsSixteenHexChars() {
        let id = JobId.generate()
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit })
    }
}
