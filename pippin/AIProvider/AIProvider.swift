import Foundation

public protocol AIProvider: Sendable {
    func complete(prompt: String, system: String) throws -> String
}

public enum AIProviderError: LocalizedError, Sendable {
    case networkError(String)
    case apiError(Int, String)
    case timeout
    case providerUnreachable(String)
    case decodingFailed(String)
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case let .networkError(msg): return "Network error: \(msg)"
        case let .apiError(code, msg): return "API error \(code): \(msg)"
        case .timeout: return "AI request timed out"
        case let .providerUnreachable(msg): return msg
        case let .decodingFailed(msg): return "Failed to decode AI response: \(msg)"
        case .missingAPIKey:
            return "Claude API key not set. Use --api-key, set ANTHROPIC_API_KEY, or run: get-secret \"Anthropic API\""
        }
    }
}

/// `true` when this pippin process was spawned by `pippin mcp-server`.
/// The MCP runtime has a 60s hard cap per child invocation; AI providers
/// shorten their timeouts and run preflight pings in this mode so a
/// silent SIGKILL doesn't masquerade as a model failure.
@inlinable
public func isMCPContext() -> Bool {
    ProcessInfo.processInfo.environment["PIPPIN_MCP"] == "1"
}

/// AI request budget. CLI mode gets the long path; MCP mode stays
/// well under `MCPServerRuntime.defaultChildTimeoutSeconds` (60s) so
/// the JSON-RPC client sees a typed AI error rather than a SIGKILL.
@inlinable
public func aiRequestTimeoutSeconds() -> TimeInterval {
    isMCPContext() ? 50 : 120
}

// MARK: - Shared synchronous HTTP helper

/// Send a URLRequest synchronously using DispatchSemaphore.
/// Returns (data, HTTPURLResponse) or throws on network/timeout error.
/// `waitTimeoutSeconds` is the upper bound on the semaphore wait; it should
/// be at least a few seconds longer than the URLRequest's own
/// `timeoutInterval` so we don't beat URLSession to the punch.
/// nonisolated(unsafe): each captured var is written once by the callback before semaphore.signal();
/// the happens-before guarantee from semaphore.wait() makes the read safe.
func sendSynchronousRequest(
    _ request: URLRequest,
    waitTimeoutSeconds: Int = 125
) throws -> (Data, HTTPURLResponse) {
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

    let waitResult = semaphore.wait(timeout: .now() + .seconds(waitTimeoutSeconds))
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
