import Foundation

public protocol EmbeddingProvider: Sendable {
    func embed(text: String) throws -> [Float]
    /// Embed multiple texts in a single request. Default implementation falls back to individual calls.
    func embedBatch(texts: [String]) throws -> [[Float]]
}

public extension EmbeddingProvider {
    func embedBatch(texts: [String]) throws -> [[Float]] {
        try texts.map { try embed(text: $0) }
    }
}

public struct OllamaEmbeddingProvider: EmbeddingProvider {
    public let baseURL: String
    public let model: String

    public init(baseURL: String = "http://localhost:11434", model: String = "nomic-embed-text") {
        self.baseURL = baseURL
        self.model = model
    }

    public func embed(text: String) throws -> [Float] {
        try embedBatch(texts: [text]).first ?? []
    }

    /// Send all texts in a single /api/embed request (Ollama supports array `input`).
    /// Returns embeddings in the same order as `texts`.
    public func embedBatch(texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let url = URL(string: "\(baseURL)/api/embed") else {
            throw MailAIError.embeddingFailed("Invalid Ollama URL: \(baseURL)")
        }

        let body: [String: Any] = [
            "model": model,
            "input": texts,
        ]

        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Uses sendSynchronousRequest() from AIProvider/AIProvider.swift (same PippinLib module)
        let (data, httpResponse) = try sendSynchronousRequest(request)

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "(no body)"
            throw MailAIError.embeddingFailed("HTTP \(httpResponse.statusCode): \(detail)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embeddings = json["embeddings"] as? [[Double]]
        else {
            let raw = String(data: data, encoding: .utf8) ?? "(undecodable)"
            throw MailAIError.embeddingFailed("Could not parse embeddings from response: \(raw)")
        }

        return embeddings.map { $0.map { Float($0) } }
    }
}
