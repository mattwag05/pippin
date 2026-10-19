import Foundation

public enum MailAIError: LocalizedError, Sendable {
    case malformedAIResponse(String)
    case emptyEmbeddingIndex
    case embeddingFailed(String)
    case unsupportedEmbeddingProvider(String)
    /// The `openai` embedding backend has no default model; one must be named.
    case embeddingModelRequired(String)
    /// The index has embeddings, but none from the active embedding model.
    case noEmbeddingsForModel(String)

    public var errorDescription: String? {
        switch self {
        case let .malformedAIResponse(raw):
            return "Malformed AI response: \(raw)"
        case .emptyEmbeddingIndex:
            return "Embedding index is empty. Run 'pippin mail index' first."
        case let .embeddingFailed(msg):
            return "Embedding failed: \(msg)"
        case let .unsupportedEmbeddingProvider(provider):
            return "Unsupported embedding provider '\(provider)'. Use 'ollama' or 'openai'."
        case let .embeddingModelRequired(provider):
            return "The '\(provider)' embedding provider needs a model. Set ai.embeddings.model in ~/.config/pippin/config.json or pass --model."
        case let .noEmbeddingsForModel(key):
            return "No messages are indexed with the active embedding model (\(key)). Run 'pippin mail index' to index with it."
        }
    }
}
