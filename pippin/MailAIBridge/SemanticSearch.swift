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

        let ranked: [SemanticSearchResult] = records.compactMap { record in
            let storedFloats = deserializeEmbedding(record.embedding)
            guard !storedFloats.isEmpty else { return nil }
            let score = cosineSimilarity(queryFloats, storedFloats)
            return SemanticSearchResult(compoundId: record.compoundId, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }

        // Load messages concurrently — JXA calls are independent osascript processes.
        nonisolated(unsafe) var loaded: [(index: Int, message: MailMessage)] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for (i, result) in ranked.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard let message = try? loader(result.compoundId) else { return }
                lock.withLock { loaded.append((index: i, message: message)) }
            }
        }
        group.wait()
        return loaded.sorted { $0.index < $1.index }.map(\.message)
    }
}
