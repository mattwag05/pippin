import GRDB
@testable import PippinLib
import XCTest

final class EmbeddingStoreTests: XCTestCase {
    private func makeStore() throws -> EmbeddingStore {
        let tmpPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
        return try EmbeddingStore(dbPath: tmpPath)
    }

    private func makeRecord(
        id: String = "a||INBOX||1",
        hash: String = "abc123",
        messageDate: String? = "2026-03-24T12:00:00Z"
    ) -> EmbeddingRecord {
        let floats: [Float] = [1.0, 2.0, 3.0]
        return EmbeddingRecord(
            compoundId: id,
            embedding: serializeEmbedding(floats),
            bodyHash: hash,
            model: "nomic-embed-text",
            indexedAt: "2026-03-25T00:00:00Z",
            messageDate: messageDate
        )
    }

    func testUpsertRoundTrip() throws {
        let store = try makeStore()
        let record = makeRecord()
        try store.upsert(record)
        XCTAssertTrue(store.isCurrent(compoundId: record.compoundId, messageDate: "2026-03-24T12:00:00Z"))
        XCTAssertFalse(store.isCurrent(compoundId: "nonexistent||INBOX||0", messageDate: "2026-03-24T12:00:00Z"))
        let fetched = try store.allEmbeddings().first
        XCTAssertEqual(fetched?.compoundId, record.compoundId)
        XCTAssertEqual(fetched?.bodyHash, record.bodyHash)
        XCTAssertEqual(fetched?.model, record.model)
        XCTAssertEqual(fetched?.indexedAt, record.indexedAt)
        XCTAssertEqual(fetched?.embedding, record.embedding)
        XCTAssertEqual(fetched?.messageDate, record.messageDate)
    }

    /// pippin-log5: an id Mail reassigned to another message, or a legacy row
    /// with no date, is not current, so `mail index` re-embeds it.
    func testIsCurrentRequiresSameMessageDate() throws {
        let store = try makeStore()
        try store.upsert(makeRecord(id: "a||INBOX||1"))
        try store.upsert(makeRecord(id: "a||INBOX||2", messageDate: nil))
        XCTAssertTrue(store.isCurrent(compoundId: "a||INBOX||1", messageDate: "2026-03-24T12:00:00.000Z"))
        XCTAssertFalse(store.isCurrent(compoundId: "a||INBOX||1", messageDate: "2026-04-01T08:00:00Z"))
        XCTAssertFalse(store.isCurrent(compoundId: "a||INBOX||2", messageDate: "2026-03-24T12:00:00Z"))
    }

    /// A store created before message dates existed gains the column on open,
    /// and its rows read back with no date.
    func testMigratesLegacyStoreWithoutMessageDate() throws {
        let path = NSTemporaryDirectory() + UUID().uuidString + ".db"
        let legacy = try DatabaseQueue(path: path)
        try legacy.write { db in
            try db.execute(sql: """
            CREATE TABLE email_embeddings (
                compound_id TEXT PRIMARY KEY, embedding BLOB NOT NULL,
                body_hash TEXT NOT NULL, model TEXT NOT NULL, indexed_at TEXT NOT NULL
            )
            """)
            try db.execute(
                sql: "INSERT INTO email_embeddings VALUES ('a||INBOX||1', ?, 'h', 'm', '2026-01-01T00:00:00Z')",
                arguments: [serializeEmbedding([1, 0])]
            )
        }
        try legacy.close()
        let store = try EmbeddingStore(dbPath: path)
        XCTAssertEqual(try store.allEmbeddings().map(\.compoundId), ["a||INBOX||1"])
        XCTAssertNil(try store.allEmbeddings().first?.messageDate)
        XCTAssertFalse(store.isCurrent(compoundId: "a||INBOX||1", messageDate: "2026-01-01T00:00:00Z"))
        try store.upsert(makeRecord(id: "a||INBOX||1"))
        XCTAssertTrue(store.isCurrent(compoundId: "a||INBOX||1", messageDate: "2026-03-24T12:00:00Z"))
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
