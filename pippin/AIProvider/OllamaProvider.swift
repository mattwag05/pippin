import Foundation

public struct OllamaProvider: AIProvider {
    public let baseURL: String
    public let model: String

    public init(baseURL: String = "http://localhost:11434", model: String = "llama3.2") {
        self.baseURL = baseURL
        self.model = model
    }

    public func complete(prompt: String, system: String) throws -> String {
        try complete(prompt: prompt, system: system, options: AICompletionOptions())
    }

    /// `/api/generate` request body. Pure (no network) so the `format: json`
    /// native-JSON wiring is unit-testable. Native JSON mode is safe for the
    /// default `gemma4` (no thinking pass); thinking models (e.g. Qwen3.6) are
    /// served via the OpenAI path, not here.
    func requestBody(prompt: String, system: String, jsonMode: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "system": system,
            "stream": false,
        ]
        if jsonMode { body["format"] = "json" }
        return body
    }

    public func complete(prompt: String, system: String, options: AICompletionOptions) throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw AIProviderError.networkError("Invalid Ollama URL: \(baseURL)")
        }

        // Fast preflight: if `ollama serve` isn't running, fail in <3s with
        // an actionable message rather than letting the agent or MCP client
        // wait the full request budget. Mirrors the philosophy of the MCP
        // runChild cap: typed errors beat silent SIGKILLs. Stays outside the
        // retry — `.providerUnreachable` is non-transient (the server is down).
        try preflight()

        let httpBody = try JSONSerialization.data(withJSONObject: requestBody(prompt: prompt, system: system, jsonMode: options.jsonMode))

        return try withAIRetry(totalBudget: aiRequestTimeoutSeconds()) { attemptTimeout in
            var request = URLRequest(url: url, timeoutInterval: attemptTimeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = httpBody

            let (data, httpResponse) = try sendSynchronousRequest(
                request,
                waitTimeoutSeconds: Int(attemptTimeout) + 5
            )

            guard httpResponse.statusCode == 200 else {
                // HTTP 404 with Ollama's model-not-found body means the
                // configured model isn't pulled — a config problem, not a
                // generic API failure. Throw it typed (non-transient, so the
                // retry loop rethrows immediately) with a best-effort list of
                // pulled models so the remediation can name alternatives.
                if httpResponse.statusCode == 404, Self.isModelNotFoundBody(data) {
                    throw AIProviderError.modelNotFound(
                        model: model,
                        available: Self.fetchAvailableModels(baseURL: baseURL) ?? []
                    )
                }
                let detail = String(data: data, encoding: .utf8) ?? ""
                throw AIProviderError.apiError(httpResponse.statusCode, detail)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["response"] as? String
            else {
                throw AIProviderError.decodingFailed("Missing 'response' field in Ollama response")
            }

            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 2-second `GET /api/version` probe. Throws `.providerUnreachable`
    /// when Ollama is down so the caller distinguishes "no model server"
    /// from "model server is slow."
    private func preflight() throws {
        guard let url = URL(string: "\(baseURL)/api/version") else { return }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        do {
            let (_, response) = try sendSynchronousRequest(request, waitTimeoutSeconds: 5)
            if response.statusCode != 200 {
                throw AIProviderError.providerUnreachable(
                    "Ollama at \(baseURL) returned HTTP \(response.statusCode) on preflight — is the server healthy?"
                )
            }
        } catch let error as AIProviderError {
            switch error {
            case .timeout, .networkError:
                throw AIProviderError.providerUnreachable(
                    "Ollama at \(baseURL) is unreachable — start it with `ollama serve` (or set ai.ollama.url in ~/.config/pippin/config.json)"
                )
            default:
                throw error
            }
        }
    }
}

// MARK: - Model availability (shared with `pippin doctor`)

public extension OllamaProvider {
    /// Pure: given the model names returned by `/api/tags` and the configured
    /// model, return `true` when the configured model is present. Allows
    /// base-name fuzzy matching so `gemma4:latest` configured matches `gemma4`
    /// available (and vice-versa).
    static func modelIsAvailable(configured: String, available: [String]) -> Bool {
        if available.contains(configured) { return true }
        let configuredBase = configured.split(separator: ":").first.map(String.init) ?? configured
        return available.contains { name in
            let base = name.split(separator: ":").first.map(String.init) ?? name
            return base == configuredBase
        }
    }

    /// Pure: parse an `/api/tags` response body into the pulled model names.
    /// Returns `nil` when the body isn't the expected shape.
    static func parseTagsResponse(_ data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    /// Pure: `true` when an Ollama error body is the model-not-found shape,
    /// e.g. `{"error":"model \"gemma4\" not found, try pulling it first"}`.
    static func isModelNotFoundBody(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["error"] as? String
        else { return false }
        return message.contains("model") && message.contains("not found")
    }

    /// Best-effort GET of `{baseURL}/api/tags`. Returns the pulled model
    /// names, or `nil` on any failure (unreachable, non-200, unexpected
    /// shape) — the probe must never mask the error that prompted it.
    static func fetchAvailableModels(baseURL: String) -> [String]? {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "GET"
        guard let (data, response) = try? sendSynchronousRequest(request, waitTimeoutSeconds: 5),
              response.statusCode == 200
        else { return nil }
        return parseTagsResponse(data)
    }
}
