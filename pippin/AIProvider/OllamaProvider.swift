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

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "system": system,
            "stream": false,
        ]

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try sendSynchronousRequest(request)

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
