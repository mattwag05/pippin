import Foundation

public protocol EmbeddingProvider: Sendable {
    func embed(text: String) throws -> [Float]
    /// Embed multiple texts in a single API call. Default implementation falls back to sequential calls.
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

    /// Request timeout policy for embedding calls. Single source of truth so
    /// both `embed` and `embedBatch` stay MCP-safe (see callers for rationale):
    /// - Under MCP (`PIPPIN_MCP=1`) every call uses the MCP-aware budget
    ///   (`aiRequestTimeoutSeconds()` = 50s), well under the 60s child cap.
    /// - In CLI, a single embed gets 120s; a batch (potentially large) gets 300s.
    static func requestTimeout(batch: Bool) -> TimeInterval {
        if isMCPContext() { return aiRequestTimeoutSeconds() }
        return batch ? 300 : aiRequestTimeoutSeconds()
    }

    public func embed(text: String) throws -> [Float] {
        guard let url = URL(string: "\(baseURL)/api/embed") else {
            throw MailAIError.embeddingFailed("Invalid Ollama URL: \(baseURL)")
        }

        let body: [String: Any] = [
            "model": model,
            "input": text,
        ]

        // MCP-aware budget (50s under PIPPIN_MCP=1) keeps a slow embedding
        // server from blowing the 60s child cap and being SIGKILLed — see
        // requestTimeout(batch:). (Was a hardcoded 120s that ignored MCP.)
        let timeout = Self.requestTimeout(batch: false)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Uses sendSynchronousRequest() from AIProvider/AIProvider.swift (same PippinLib module)
        let (data, httpResponse) = try sendSynchronousRequest(request, waitTimeoutSeconds: Int(timeout) + 5)

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "(no body)"
            throw MailAIError.embeddingFailed("HTTP \(httpResponse.statusCode): \(detail)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embeddings = json["embeddings"] as? [[Double]],
              let first = embeddings.first
        else {
            let raw = String(data: data, encoding: .utf8) ?? "(undecodable)"
            throw MailAIError.embeddingFailed("Could not parse embeddings from response: \(raw)")
        }

        return first.map { Float($0) }
    }

    /// Batch embed multiple texts in a single Ollama API call.
    /// Ollama's /api/embed endpoint natively supports array input.
    public func embedBatch(texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        guard let url = URL(string: "\(baseURL)/api/embed") else {
            throw MailAIError.embeddingFailed("Invalid Ollama URL: \(baseURL)")
        }

        let body: [String: Any] = [
            "model": model,
            "input": texts,
        ]

        // CLI keeps a generous 300s budget for large batches; under MCP this
        // clamps to the 50s MCP-aware budget so the call can't be SIGKILLed past
        // the 60s child cap. (Was an unconditional 300s that ignored MCP.)
        let timeout = Self.requestTimeout(batch: true)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try sendSynchronousRequest(request, waitTimeoutSeconds: Int(timeout) + 5)

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "(no body)"
            throw MailAIError.embeddingFailed("HTTP \(httpResponse.statusCode): \(detail)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embeddings = json["embeddings"] as? [[Double]]
        else {
            let raw = String(data: data, encoding: .utf8) ?? "(undecodable)"
            throw MailAIError.embeddingFailed("Could not parse batch embeddings from response: \(raw)")
        }

        guard embeddings.count == texts.count else {
            throw MailAIError.embeddingFailed("Batch count mismatch: sent \(texts.count), got \(embeddings.count)")
        }

        return embeddings.map { $0.map { Float($0) } }
    }
}
