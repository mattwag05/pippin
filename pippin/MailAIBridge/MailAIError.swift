import Foundation

public enum MailAIError: LocalizedError, Sendable {
    case malformedAIResponse(String)
    case emptyEmbeddingIndex
    case embeddingFailed(String)
    case unsupportedEmbeddingProvider(String)

    public var errorDescription: String? {
        switch self {
        case let .malformedAIResponse(raw):
            return "Malformed AI response: \(raw)"
        case .emptyEmbeddingIndex:
            return "Embedding index is empty. Run 'pippin mail index' first."
        case let .embeddingFailed(msg):
            return "Embedding failed: \(msg)"
        case let .unsupportedEmbeddingProvider(provider):
            return "Unsupported embedding provider '\(provider)' — only 'ollama' is supported"
        }
    }
}
