import Foundation

/// AIProvider for any OpenAI-compatible Chat Completions endpoint
/// (`POST {baseURL}/chat/completions`). One provider covers OpenAI itself,
/// OpenRouter, a homelab gateway (e.g. Manifest), [local-llm], vLLM, LM Studio,
/// llama.cpp's server, and Ollama's own `/v1` shim — the backend is just a
/// `baseURL` + `model` + optional key.
///
/// The API key is optional: local endpoints that don't authenticate simply
/// omit the `Authorization` header. `max_tokens` is intentionally not sent so
/// each server applies its own default (some OpenAI-compatible servers reject
/// an explicit cap).
public struct OpenAIProvider: AIProvider {
    public let baseURL: String
    public let model: String
    private let apiKey: String?

    public init(
        baseURL: String = "http://localhost:11434/v1",
        model: String = "gpt-4o-mini",
        apiKey: String? = nil
    ) {
        // Drop a trailing slash so `"\(baseURL)/chat/completions"` never doubles up.
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.model = model
        // Treat an empty key the same as no key (local endpoints need no auth).
        self.apiKey = (apiKey?.isEmpty == false) ? apiKey : nil
    }

    public func complete(prompt: String, system: String) throws -> String {
        let request = try buildRequest(prompt: prompt, system: system)
        let timeout = aiRequestTimeoutSeconds()
        let (data, httpResponse) = try sendSynchronousRequest(
            request,
            waitTimeoutSeconds: Int(timeout) + 5
        )

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.apiError(httpResponse.statusCode, detail)
        }

        return try Self.parseCompletion(data)
    }

    /// Build the chat-completions POST request. Pure (no network I/O) so the
    /// endpoint, headers, and body shape are unit-testable.
    func buildRequest(prompt: String, system: String) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AIProviderError.networkError("Invalid OpenAI-compatible base URL: \(baseURL)")
        }

        var messages: [[String: String]] = []
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
        ]

        var request = URLRequest(url: url, timeoutInterval: aiRequestTimeoutSeconds())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Extract `choices[0].message.content` from an OpenAI-compatible
    /// chat-completions response.
    static func parseCompletion(_ data: Data) throws -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw AIProviderError.decodingFailed(
                "Missing choices[0].message.content in OpenAI-compatible response"
            )
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
