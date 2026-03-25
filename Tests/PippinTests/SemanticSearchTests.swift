@testable import PippinLib
import XCTest

private struct FakeSemanticEmbeddingProvider: EmbeddingProvider {
    let fixedEmbedding: [Float]
    func embed(text _: String) throws -> [Float] { fixedEmbedding }
}

private struct ThrowingEmbeddingProvider: EmbeddingProvider {
    func embed(text _: String) throws -> [Float] {
        throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "provider exploded"])
    }
}

private func makeStore() throws -> EmbeddingStore {
    let tmpPath = NSTemporaryDirectory() + UUID().uuidString + ".db"
    return try EmbeddingStore(dbPath: tmpPath)
}

private func insertRecord(store: EmbeddingStore, compoundId: String, embedding: [Float]) throws {
    let record = EmbeddingRecord(
        compoundId: compoundId,
        embedding: serializeEmbedding(embedding),
        bodyHash: "hash-\(compoundId)",
        model: "nomic-embed-text",
        indexedAt: "2026-01-01T00:00:00Z"
    )
    try store.upsert(record)
}

final class SemanticSearchTests: XCTestCase {

    // MARK: - 1. Empty store throws emptyEmbeddingIndex

    func testSearchEmptyStoreThrows() throws {
        let store = try makeStore()
        let provider = FakeSemanticEmbeddingProvider(fixedEmbedding: [1, 0, 0])
        XCTAssertThrowsError(try SemanticSearch.search(query: "hello", store: store, provider: provider)) { error in
            guard case MailAIError.emptyEmbeddingIndex = error else {
                XCTFail("Expected emptyEmbeddingIndex, got \(error)")
                return
            }
        }
    }

    // MARK: - 2. Returns top results; record matching query embedding is first

    func testSearchReturnsTopResults() throws {
        let store = try makeStore()
        // Orthogonal unit vectors — cosine similarity with query [0,1,0]:
        // A=[1,0,0] → 0.0, B=[0,1,0] → 1.0, C=[0,0,1] → 0.0
        try insertRecord(store: store, compoundId: "A", embedding: [1, 0, 0])
        try insertRecord(store: store, compoundId: "B", embedding: [0, 1, 0])
        try insertRecord(store: store, compoundId: "C", embedding: [0, 0, 1])

        let provider = FakeSemanticEmbeddingProvider(fixedEmbedding: [0, 1, 0])
        let results = try SemanticSearch.search(query: "irrelevant", store: store, provider: provider)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.compoundId, "B")
        XCTAssertEqual(results.first?.score ?? 0.0, 1.0, accuracy: 0.001)
    }

    // MARK: - 3. Respects limit

    func testSearchRespectsLimit() throws {
        let store = try makeStore()
        for i in 0..<5 {
            try insertRecord(store: store, compoundId: "msg\(i)", embedding: [Float(i), 1, 0])
        }
        let provider = FakeSemanticEmbeddingProvider(fixedEmbedding: [1, 0, 0])
        let results = try SemanticSearch.search(query: "q", store: store, provider: provider, limit: 2)
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - 4. Results sorted by score descending

    func testSearchSortedByScoreDescending() throws {
        let store = try makeStore()
        // query = [1, 0, 0]
        // high similarity: [0.9, 0.1, 0] → dot ≈ 0.9
        // mid similarity:  [0.5, 0.5, 0] → dot ≈ 0.5/norm
        // low similarity:  [0.1, 0.9, 0] → dot ≈ 0.1/norm
        try insertRecord(store: store, compoundId: "low",  embedding: [0.1, 0.9, 0])
        try insertRecord(store: store, compoundId: "mid",  embedding: [0.5, 0.5, 0])
        try insertRecord(store: store, compoundId: "high", embedding: [0.9, 0.1, 0])

        let provider = FakeSemanticEmbeddingProvider(fixedEmbedding: [1, 0, 0])
        let results = try SemanticSearch.search(query: "q", store: store, provider: provider)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].compoundId, "high")
        XCTAssertEqual(results[1].compoundId, "mid")
        XCTAssertEqual(results[2].compoundId, "low")
        // Scores must be in descending order
        for i in 0..<(results.count - 1) {
            XCTAssertGreaterThanOrEqual(results[i].score, results[i + 1].score)
        }
    }

    // MARK: - 5. Single record returns that record

    func testSearchSingleResult() throws {
        let store = try makeStore()
        try insertRecord(store: store, compoundId: "only-one", embedding: [1, 0, 0])
        let provider = FakeSemanticEmbeddingProvider(fixedEmbedding: [1, 0, 0])
        let results = try SemanticSearch.search(query: "q", store: store, provider: provider)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.compoundId, "only-one")
    }

    // MARK: - 6. SemanticSearchResult Codable round-trip

    func testSemanticSearchResultCodable() throws {
        let original = SemanticSearchResult(compoundId: "acct||INBOX||42", score: 0.987)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SemanticSearchResult.self, from: encoded)
        XCTAssertEqual(decoded.compoundId, original.compoundId)
        XCTAssertEqual(decoded.score, original.score, accuracy: 0.0001)
    }

    // MARK: - 7. Provider throw propagates as embeddingFailed

    func testSearchEmbeddingFailurePropagates() throws {
        let store = try makeStore()
        try insertRecord(store: store, compoundId: "msg1", embedding: [1, 0, 0])
        let provider = ThrowingEmbeddingProvider()
        XCTAssertThrowsError(try SemanticSearch.search(query: "q", store: store, provider: provider)) { error in
            guard case MailAIError.embeddingFailed = error else {
                XCTFail("Expected embeddingFailed, got \(error)")
                return
            }
        }
    }
}
