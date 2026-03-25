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

/// Returns a fake `messageLoader` closure that builds stub `MailMessage` values from compound IDs.
private func fakeLoader() -> (String) throws -> MailMessage {
    return { compoundId in
        MailMessage(
            id: compoundId,
            account: "test-account",
            mailbox: "INBOX",
            subject: "Subject for \(compoundId)",
            from: "sender@example.com",
            to: ["recipient@example.com"],
            date: "2026-01-01T00:00:00Z",
            read: false
        )
    }
}

final class SemanticSearchTests: XCTestCase {

    // MARK: - 1. Empty store throws emptyEmbeddingIndex

    func testSearchEmptyStoreThrows() throws {
        let store = try makeStore()
        let provider = FakeSemanticEmbeddingProvider(fixedEmbedding: [1, 0, 0])
        XCTAssertThrowsError(
            try SemanticSearch.search(query: "hello", store: store, provider: provider, messageLoader: fakeLoader())
        ) { error in
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
        let results = try SemanticSearch.search(
            query: "irrelevant", store: store, provider: provider, messageLoader: fakeLoader()
        )

        XCTAssertFalse(results.isEmpty)
        // B has cosine similarity 1.0 — must be ranked first
        XCTAssertEqual(results.first?.id, "B")
    }

    // MARK: - 3. Respects limit

    func testSearchRespectsLimit() throws {
        let store = try makeStore()
        for i in 0..<5 {
            try insertRecord(store: store, compoundId: "msg\(i)", embedding: [Float(i), 1, 0])
        }
        let provider = FakeSemanticEmbeddingProvider(fixedEmbedding: [1, 0, 0])
        let results = try SemanticSearch.search(
            query: "q", store: store, provider: provider, limit: 2, messageLoader: fakeLoader()
        )
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - 4. Results sorted by score descending (highest similarity first)

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
        let results = try SemanticSearch.search(
            query: "q", store: store, provider: provider, messageLoader: fakeLoader()
        )

        XCTAssertEqual(results.count, 3)
        // Results ordered highest → lowest similarity
        XCTAssertEqual(results[0].id, "high")
        XCTAssertEqual(results[1].id, "mid")
        XCTAssertEqual(results[2].id, "low")
    }

    // MARK: - 5. Single record returns that record

    func testSearchSingleResult() throws {
        let store = try makeStore()
        try insertRecord(store: store, compoundId: "only-one", embedding: [1, 0, 0])
        let provider = FakeSemanticEmbeddingProvider(fixedEmbedding: [1, 0, 0])
        let results = try SemanticSearch.search(
            query: "q", store: store, provider: provider, messageLoader: fakeLoader()
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "only-one")
    }

    // MARK: - 6. SemanticSearchResult Codable round-trip (internal intermediate type)

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
        XCTAssertThrowsError(
            try SemanticSearch.search(query: "q", store: store, provider: provider, messageLoader: fakeLoader())
        ) { error in
            guard case MailAIError.embeddingFailed = error else {
                XCTFail("Expected embeddingFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - 8. messageLoader failures are skipped (try? behavior)

    func testSearchSkipsFailedMessageLoads() throws {
        let store = try makeStore()
        try insertRecord(store: store, compoundId: "good", embedding: [1, 0, 0])
        try insertRecord(store: store, compoundId: "bad",  embedding: [0.9, 0, 0])

        let provider = FakeSemanticEmbeddingProvider(fixedEmbedding: [1, 0, 0])
        let failingLoader: (String) throws -> MailMessage = { compoundId in
            if compoundId == "bad" {
                throw NSError(domain: "TestError", code: 404, userInfo: nil)
            }
            return MailMessage(
                id: compoundId,
                account: "test",
                mailbox: "INBOX",
                subject: "Subject",
                from: "sender@example.com",
                to: [],
                date: "2026-01-01T00:00:00Z",
                read: false
            )
        }
        let results = try SemanticSearch.search(
            query: "q", store: store, provider: provider, messageLoader: failingLoader
        )
        // "bad" load fails silently; only "good" returned
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "good")
    }
}
