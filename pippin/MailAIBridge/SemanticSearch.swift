import Foundation

public enum SemanticSearch {

    /// Search for messages semantically similar to `query`.
    /// Throws `MailAIError.emptyEmbeddingIndex` if the index is empty (run `pippin mail index` first).
    public static func search(
        query: String,
        store: EmbeddingStore,
        provider: any EmbeddingProvider,
        limit: Int = 10
    ) throws -> [SemanticSearchResult] {
        guard try !store.isEmpty() else {
            throw MailAIError.emptyEmbeddingIndex
        }

        let queryFloats: [Float]
        do {
            queryFloats = try provider.embed(text: query)
        } catch {
            throw MailAIError.embeddingFailed(error.localizedDescription)
        }

        let records = try store.allEmbeddings()

        let results: [SemanticSearchResult] = records.compactMap { record in
            let storedFloats = deserializeEmbedding(record.embedding)
            guard !storedFloats.isEmpty else { return nil }
            let score = cosineSimilarity(queryFloats, storedFloats)
            return SemanticSearchResult(compoundId: record.compoundId, score: score)
        }

        return results
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }
}
