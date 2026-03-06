@testable import PippinLib
import XCTest

final class TranscriptCacheTests: XCTestCase {
    private func makeCache() throws -> TranscriptCache {
        // Use in-memory path via a temp file
        let tmpPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
        return try TranscriptCache(dbPath: tmpPath)
    }

    func testGetMissReturnsNil() throws {
        let cache = try makeCache()
        let result = try cache.get(memoId: "nonexistent-id")
        XCTAssertNil(result)
    }

    func testSetAndGet() throws {
        let cache = try makeCache()
        try cache.set(memoId: "memo-1", transcript: "Hello world", provider: "parakeet-mlx")
        let entry = try cache.get(memoId: "memo-1")
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.memoId, "memo-1")
        XCTAssertEqual(entry?.transcript, "Hello world")
        XCTAssertEqual(entry?.provider, "parakeet-mlx")
        XCTAssertFalse(try XCTUnwrap(entry?.transcribedAt.isEmpty))
    }

    func testUpdateExistingEntry() throws {
        let cache = try makeCache()
        try cache.set(memoId: "memo-2", transcript: "First", provider: "parakeet-mlx")
        try cache.set(memoId: "memo-2", transcript: "Updated", provider: "ollama")
        let entry = try cache.get(memoId: "memo-2")
        XCTAssertEqual(entry?.transcript, "Updated")
        XCTAssertEqual(entry?.provider, "ollama")
    }

    func testDelete() throws {
        let cache = try makeCache()
        try cache.set(memoId: "memo-3", transcript: "To be deleted", provider: "parakeet-mlx")
        XCTAssertNotNil(try cache.get(memoId: "memo-3"))
        try cache.delete(memoId: "memo-3")
        XCTAssertNil(try cache.get(memoId: "memo-3"))
    }

    func testDeleteNonExistentIsNoOp() throws {
        let cache = try makeCache()
        // Should not throw
        XCTAssertNoThrow(try cache.delete(memoId: "does-not-exist"))
    }

    func testMultipleEntries() throws {
        let cache = try makeCache()
        for i in 0 ..< 5 {
            try cache.set(memoId: "memo-\(i)", transcript: "Transcript \(i)", provider: "parakeet-mlx")
        }
        for i in 0 ..< 5 {
            let entry = try cache.get(memoId: "memo-\(i)")
            XCTAssertEqual(entry?.transcript, "Transcript \(i)")
        }
    }

    func testTranscribedAtIsISO8601() throws {
        let cache = try makeCache()
        try cache.set(memoId: "memo-ts", transcript: "text", provider: "parakeet-mlx")
        let entry = try XCTUnwrap(try cache.get(memoId: "memo-ts"))
        // Should parse as a valid ISO 8601 date
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let date = formatter.date(from: entry.transcribedAt)
        XCTAssertNotNil(date, "transcribedAt '\(entry.transcribedAt)' is not valid ISO 8601")
    }
}
