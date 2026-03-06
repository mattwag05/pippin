import Foundation

public protocol AIProvider: Sendable {
    func complete(prompt: String, system: String) throws -> String
}

public enum AIProviderError: LocalizedError, Sendable {
    case networkError(String)
    case apiError(Int, String)
    case timeout
    case decodingFailed(String)
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case let .networkError(msg): return "Network error: \(msg)"
        case let .apiError(code, msg): return "API error \(code): \(msg)"
        case .timeout: return "AI request timed out after 120 seconds"
        case let .decodingFailed(msg): return "Failed to decode AI response: \(msg)"
        case .missingAPIKey:
            return "Claude API key not set. Use --api-key, set ANTHROPIC_API_KEY, or run: get-secret \"Anthropic API\""
        }
    }
}

// MARK: - Shared synchronous HTTP helper

/// Send a URLRequest synchronously using DispatchSemaphore.
/// Returns (data, HTTPURLResponse) or throws on network/timeout error.
/// nonisolated(unsafe): each captured var is written once by the callback before semaphore.signal();
/// the happens-before guarantee from semaphore.wait() makes the read safe.
func sendSynchronousRequest(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    nonisolated(unsafe) var resultData: Data?
    nonisolated(unsafe) var resultResponse: URLResponse?
    nonisolated(unsafe) var resultError: Error?

    let semaphore = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        resultData = data
        resultResponse = response
        resultError = error
        semaphore.signal()
    }
    task.resume()

    // 125s overall wait — slightly longer than the 120s timeout in the request itself
    let waitResult = semaphore.wait(timeout: .now() + .seconds(125))
    guard waitResult == .success else {
        task.cancel()
        throw AIProviderError.timeout
    }

    if let error = resultError {
        throw AIProviderError.networkError(error.localizedDescription)
    }

    guard let data = resultData, let httpResponse = resultResponse as? HTTPURLResponse else {
        throw AIProviderError.networkError("No response received")
    }

    return (data, httpResponse)
}
