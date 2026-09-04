import Foundation

/// AIProvider for any OpenAI-compatible Chat Completions endpoint
/// (`POST {baseURL}/chat/completions`). One provider covers OpenAI itself,
/// OpenRouter, a self-hosted OpenAI-compatible gateway, vLLM, LM Studio,
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
    /// Config opt-in (`ai.openai.structuredOutputs`) for native JSON mode. OFF by
    /// default because `response_format` support is server-dependent — not every
    /// OpenAI-compatible backend (older vLLM/llama.cpp, some local servers) accepts it, and a
    /// server that rejects it would 400 a request that otherwise works. Enable it
    /// only against a backend you've verified accepts `response_format`.
    private let structuredOutputs: Bool

    public init(
        baseURL: String = "http://localhost:11434/v1",
        model: String = "gpt-4o-mini",
        apiKey: String? = nil,
        structuredOutputs: Bool = false
    ) {
        // Drop a trailing slash so `"\(baseURL)/chat/completions"` never doubles up.
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.model = model
        // Treat an empty key the same as no key (local endpoints need no auth).
        self.apiKey = (apiKey?.isEmpty == false) ? apiKey : nil
        self.structuredOutputs = structuredOutputs
    }

    public func complete(prompt: String, system: String) throws -> String {
        try complete(prompt: prompt, system: system, options: AICompletionOptions())
    }

    public func complete(prompt: String, system: String, options: AICompletionOptions) throws -> String {
        try withAIRetry(totalBudget: aiRequestTimeoutSeconds()) { attemptTimeout in
            let request = try buildRequest(
                prompt: prompt, system: system, options: options, timeout: attemptTimeout
            )
            let (data, httpResponse) = try sendSynchronousRequest(
                request,
                waitTimeoutSeconds: Int(attemptTimeout) + 5
            )
            guard httpResponse.statusCode == 200 else {
                throw Self.errorForHTTPStatus(
                    httpResponse.statusCode, data: data, model: model, baseURL: baseURL
                )
            }
            return try Self.parseCompletion(data)
        }
    }

    /// Classify an HTTP failure without copying untrusted provider response
    /// content into an error that can be returned or logged to a user.
    static func errorForHTTPStatus(
        _ statusCode: Int,
        data: Data,
        model: String,
        baseURL: String
    ) -> AIProviderError {
        let body = String(data: data, encoding: .utf8) ?? ""
        // A 404 whose body names the model is "model not served here", not a
        // generic API failure. Keep this typed path and its remediation.
        if statusCode == 404, body.range(of: "model", options: .caseInsensitive) != nil {
            return .remoteModelNotFound(model: model, baseURL: baseURL)
        }
        let classification: String
        switch statusCode {
        case 400 ..< 500:
            classification = "request rejected by endpoint"
        case 500 ... 599:
            classification = "endpoint server failure"
        default:
            classification = "endpoint returned an HTTP error"
        }
        return .apiError(statusCode, "OpenAI-compatible \(classification) (HTTP \(statusCode)).")
    }

    /// Build the chat-completions POST request. Pure (no network I/O) so the
    /// endpoint, headers, and body shape are unit-testable. `timeout` defaults to
    /// the full AI budget; the retry path passes the remaining budget per attempt.
    func buildRequest(
        prompt: String,
        system: String,
        jsonMode: Bool = false,
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        try buildRequest(
            prompt: prompt,
            system: system,
            options: AICompletionOptions(jsonMode: jsonMode),
            timeout: timeout
        )
    }

    func buildRequest(
        prompt: String,
        system: String,
        options: AICompletionOptions,
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AIProviderError.networkError("Invalid OpenAI-compatible base URL: \(baseURL)")
        }

        var messages: [[String: String]] = []
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": prompt])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
        ]
        if let temperature = options.temperature {
            body["temperature"] = temperature
        }
        // Native JSON mode is sent ONLY when: the caller asked for it, config
        // opted in (`structuredOutputs`), and the prompt mentions "json" — OpenAI
        // (and compatible servers) reject `response_format: json_object` with a
        // 400 unless the word "json" appears in the messages.
        if options.jsonMode, structuredOutputs, Self.mentionsJSON(prompt: prompt, system: system) {
            body["response_format"] = ["type": "json_object"]
        }

        var request = URLRequest(url: url, timeoutInterval: timeout ?? aiRequestTimeoutSeconds())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `true` when "json" appears (case-insensitively) in the prompt or system
    /// message — OpenAI requires it before honoring `response_format: json_object`.
    static func mentionsJSON(prompt: String, system: String) -> Bool {
        prompt.range(of: "json", options: .caseInsensitive) != nil
            || system.range(of: "json", options: .caseInsensitive) != nil
    }

    /// Extract `choices[0].message.content` from an OpenAI-compatible
    /// chat-completions response.
    static func parseCompletion(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let finishReason = choice["finish_reason"] as? String,
              finishReason == "stop",
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            // Never include the provider payload here. It may contain hidden
            // reasoning or tool-call arguments that must not reach logs/errors.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               !choices.isEmpty {
                throw AIProviderError.incompleteCompletion
            }
            throw AIProviderError.decodingFailed(
                "Missing choices[0].message.content in OpenAI-compatible response"
            )
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
