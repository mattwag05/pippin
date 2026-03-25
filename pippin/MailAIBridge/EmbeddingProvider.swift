import Foundation

public protocol EmbeddingProvider: Sendable {
    func embed(text: String) throws -> [Float]
}

public struct OllamaEmbeddingProvider: EmbeddingProvider {
    public let baseURL: String
    public let model: String

    public init(baseURL: String = "http://localhost:11434", model: String = "nomic-embed-text") {
        self.baseURL = baseURL
        self.model = model
    }

    public func embed(text: String) throws -> [Float] {
        guard let url = URL(string: "\(baseURL)/api/embed") else {
            throw MailAIError.embeddingFailed("Invalid Ollama URL: \(baseURL)")
        }

        let body: [String: Any] = [
            "model": model,
            "input": text,
        ]

        var request = URLRequest(url: url, timeoutInterval: 120)
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
              let embeddings = json["embeddings"] as? [[Double]],
              let first = embeddings.first
        else {
            let raw = String(data: data, encoding: .utf8) ?? "(undecodable)"
            throw MailAIError.embeddingFailed("Could not parse embeddings from response: \(raw)")
        }

        return first.map { Float($0) }
    }
}
