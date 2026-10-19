import Foundation

public enum SemanticSearch {
    /// Search for messages semantically similar to `query`.
    /// Throws `MailAIError.emptyEmbeddingIndex` if the index is empty (run `pippin mail index` first).
    ///
    /// - Parameters:
    ///   - messageLoader: Closure to load a full `MailMessage` from a compound ID.
    ///     Pass `nil` to use the default `MailBridge.readMessage(compoundId:)`. Pass a custom closure in tests.
    public static func search(
        query: String,
        store: EmbeddingStore,
        provider: any EmbeddingProvider,
        limit: Int = 10,
        messageLoader: ((String) throws -> MailMessage)? = nil
    ) throws -> [MailMessage] {
        nonisolated(unsafe) let loader: (String) throws -> MailMessage = messageLoader ?? { try MailBridge.readMessage(compoundId: $0) }
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

        // Legacy rows carry no message date, so nothing can vouch for them.
        let ranked: [(result: SemanticSearchResult, date: String)] = records.compactMap { record in
            guard let date = record.messageDate else { return nil }
            let storedFloats = deserializeEmbedding(record.embedding)
            guard !storedFloats.isEmpty else { return nil }
            let score = cosineSimilarity(queryFloats, storedFloats)
            return (SemanticSearchResult(compoundId: record.compoundId, score: score), date)
        }
        .sorted { $0.result.score > $1.result.score }

        // Load in ranked windows, silently dropping messages that fail to load
        // and hits whose id Mail has since given to a different message
        // (pippin-log5): the embedding describes the old message, not the one
        // now at that id. Later windows backfill the dropped slots.
        var messages: [MailMessage] = []
        var start = 0
        while messages.count < limit, start < ranked.count {
            let window = Array(ranked[start ..< min(start + limit - messages.count, ranked.count)])
            start += window.count
            let loaded = try runConcurrently(window) { candidate -> MailMessage? in
                let message = try loader(candidate.result.compoundId)
                return MailBodyCache.sameInstant(message.date, candidate.date) ? message : nil
            }
            messages += loaded.compactMap { $0 }
        }
        return messages
    }
}
