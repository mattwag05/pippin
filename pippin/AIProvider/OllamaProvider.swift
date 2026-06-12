import Foundation

public struct OllamaProvider: AIProvider {
    public let baseURL: String
    public let model: String

    public init(baseURL: String = "http://localhost:11434", model: String = "llama3.2") {
        self.baseURL = baseURL
        self.model = model
    }

    public func complete(prompt: String, system: String) throws -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw AIProviderError.networkError("Invalid Ollama URL: \(baseURL)")
        }

        // Fast preflight: if `ollama serve` isn't running, fail in <3s with
        // an actionable message rather than letting the agent or MCP client
        // wait the full request budget. Mirrors the philosophy of the MCP
        // runChild cap: typed errors beat silent SIGKILLs. Stays outside the
        // retry — `.providerUnreachable` is non-transient (the server is down).
        try preflight()

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "system": system,
            "stream": false,
        ]
        let httpBody = try JSONSerialization.data(withJSONObject: body)

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
