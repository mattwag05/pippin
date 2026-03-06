import Foundation

public struct ClaudeProvider: AIProvider {
    public let model: String
    private let apiKey: String

    public init(model: String = "claude-sonnet-4-6", apiKey: String) {
        self.model = model
        self.apiKey = apiKey
    }

    public func complete(prompt: String, system: String) throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw AIProviderError.networkError("Invalid Anthropic API URL")
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "messages": [
                ["role": "user", "content": prompt],
            ],
        ]

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try sendSynchronousRequest(request)

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AIProviderError.apiError(httpResponse.statusCode, detail)
        }

        // Response: {"content": [{"type": "text", "text": "..."}], ...}
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let contentArray = json["content"] as? [[String: Any]],
            let firstBlock = contentArray.first,
            firstBlock["type"] as? String == "text",
            let text = firstBlock["text"] as? String
        else {
            throw AIProviderError.decodingFailed("Unexpected Anthropic response format")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
