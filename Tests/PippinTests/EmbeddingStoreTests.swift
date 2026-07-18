@testable import PippinLib
import XCTest

final class EmbeddingStoreTests: XCTestCase {
    private func makeStore() throws -> EmbeddingStore {
        let tmpPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
        return try EmbeddingStore(dbPath: tmpPath)
    }

    private func makeRecord(id: String = "a||INBOX||1", hash: String = "abc123") -> EmbeddingRecord {
        let floats: [Float] = [1.0, 2.0, 3.0]
        return EmbeddingRecord(
            compoundId: id,
            embedding: serializeEmbedding(floats),
            bodyHash: hash,
            model: "nomic-embed-text",
            indexedAt: "2026-03-25T00:00:00Z"
        )
    }

    func testUpsertRoundTrip() throws {
        let store = try makeStore()
        let record = makeRecord()
        try store.upsert(record)
        XCTAssertTrue(store.exists(compoundId: record.compoundId))
        XCTAssertFalse(store.exists(compoundId: "nonexistent||INBOX||0"))
        let fetched = try store.allEmbeddings().first
        XCTAssertEqual(fetched?.compoundId, record.compoundId)
        XCTAssertEqual(fetched?.bodyHash, record.bodyHash)
        XCTAssertEqual(fetched?.model, record.model)
        XCTAssertEqual(fetched?.indexedAt, record.indexedAt)
        XCTAssertEqual(fetched?.embedding, record.embedding)
    }

    func testCount() throws {
        let store = try makeStore()
        try store.upsert(makeRecord(id: "a||INBOX||1"))
        try store.upsert(makeRecord(id: "a||INBOX||2"))
        try store.upsert(makeRecord(id: "a||INBOX||3"))
        XCTAssertEqual(try store.count(), 3)
    }

    func testIsEmpty() throws {
        let store = try makeStore()
        XCTAssertTrue(try store.isEmpty())
        try store.upsert(makeRecord())
        XCTAssertFalse(try store.isEmpty())
    }

    func testAllEmbeddings() throws {
        let store = try makeStore()
        try store.upsert(makeRecord(id: "a||INBOX||1"))
        try store.upsert(makeRecord(id: "a||INBOX||2"))
        let all = try store.allEmbeddings()
        XCTAssertEqual(all.count, 2)
    }

    func testSerializationRoundTrip() {
        let original: [Float] = [1.0, 2.0, 3.0]
        let data = serializeEmbedding(original)
        let roundTripped = deserializeEmbedding(data)
        XCTAssertEqual(roundTripped, original)
    }

    func testCosineSimilarityIdentical() {
        let v: [Float] = [1.0, 0.0, 1.0]
        let sim = cosineSimilarity(v, v)
        XCTAssertEqual(sim, 1.0, accuracy: 1e-6)
    }

    func testCosineSimilarityOrthogonal() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [0.0, 1.0]
        let sim = cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 1e-6)
    }

    func testCosineSimilarityZeroVector() {
        let a: [Float] = [0.0, 0.0]
        let b: [Float] = [1.0, 2.0]
        let sim = cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0)
    }
}
