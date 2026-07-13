import Foundation

/// Per-request completion options.
public struct AICompletionOptions: Sendable {
    /// Request native structured (JSON) output where the active provider — and,
    /// for the OpenAI path, the config — supports it. Best-effort: providers
    /// without a native mode (Claude) or that haven't opted in fall back to
    /// prompt-based JSON, which the callers already parse defensively
    /// (`stripAIResponseJSON`). See pippin-us2.
    public var jsonMode: Bool

    public init(jsonMode: Bool = false) {
        self.jsonMode = jsonMode
    }
}

public protocol AIProvider: Sendable {
    func complete(prompt: String, system: String) throws -> String
    /// Completion with options (e.g. `jsonMode`). Defaulted to forward to the
    /// plain `complete` below, so test fakes and providers without a native
    /// structured-output mode need not implement it.
    func complete(prompt: String, system: String, options: AICompletionOptions) throws -> String
}

public extension AIProvider {
    func complete(prompt: String, system: String, options _: AICompletionOptions) throws -> String {
        try complete(prompt: prompt, system: system)
    }
}

public enum AIProviderError: LocalizedError, Sendable {
    case networkError(String)
    case apiError(Int, String)
    case timeout
    case providerUnreachable(String)
    case decodingFailed(String)
    case missingAPIKey
    /// The configured Ollama model isn't pulled (HTTP 404 with Ollama's
    /// model-not-found body). `available` is the best-effort `/api/tags`
    /// probe result — empty when the probe failed, never an error itself.
    case modelNotFound(model: String, available: [String])

    public var errorDescription: String? {
        switch self {
        case let .networkError(msg): return "Network error: \(msg)"
        case let .apiError(code, msg): return "API error \(code): \(msg)"
        case .timeout: return "AI request timed out"
        case let .providerUnreachable(msg): return msg
        case let .decodingFailed(msg): return "Failed to decode AI response: \(msg)"
        case .missingAPIKey:
            return "Claude API key not set. Use --api-key, set ANTHROPIC_API_KEY, or run: get-secret \"Anthropic API\""
        case let .modelNotFound(model, _):
            return "Ollama model \"\(model)\" is not pulled — run `ollama pull \(model)`, or set ai.ollama.model in ~/.config/pippin/config.json to a pulled model"
        }
    }
}

/// `.modelNotFound` supplies its own remediation (`ollama pull …` plus the
/// `ai.ollama.model` config pointer), mirroring `pippin doctor`'s Ollama model
/// check, so the hint reaches both the agent envelope and the human CLI path
/// via `RemediationCatalog.resolve`. Other cases fall through to the catalog.
extension AIProviderError: RemediableError {
    public var remediation: Remediation? {
        guard case let .modelNotFound(model, available) = self else { return nil }
        var hint = """
        The configured Ollama model "\(model)" is not pulled. Pull it with \
        the command below, or set a different model under ai.ollama.model in \
        ~/.config/pippin/config.json.
        """
        if !available.isEmpty {
            let shown = available.sorted().prefix(10)
            let more = available.count > shown.count ? ", …" : ""
            hint += " Available: \(shown.joined(separator: ", "))\(more)"
        }
        return Remediation(
            humanHint: hint,
            doctorCheck: "Ollama",
            shellCommand: "ollama pull \(model)"
        )
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

// MARK: - Transient-failure retry

/// Whether an AI error is a transient failure worth retrying. Retryable:
/// HTTP 429 (rate limit) + 5xx (server/overloaded), and connection-level
/// `networkError` blips (reset/refused/lost) — all fail fast, so a retry is
/// cheap. NOT retryable: `.timeout` (already consumed the whole budget — a
/// retry would risk the MCP 60s child cap), `.providerUnreachable` (server is
/// down; preflight already failed fast), `.decodingFailed` (the same request
/// yields the same unparseable body), `.missingAPIKey`, and `.modelNotFound`
/// (retrying can't make a missing model appear).
func isTransientAIError(_ error: AIProviderError) -> Bool {
    switch error {
    case let .apiError(code, _): return code == 429 || (500 ... 599).contains(code)
    case .networkError: return true
    case .timeout, .providerUnreachable, .decodingFailed, .missingAPIKey, .modelNotFound: return false
    }
}

/// Run `attempt` with bounded retry on transient failures, sharing a single
/// `totalBudget` so the total wall-clock stays within the original request
/// envelope (critical under MCP, where the child cap is 60s — retries make
/// better use of the budget rather than multiplying it). Each attempt is given
/// the *remaining* budget as its timeout; retries stop once too little is left
/// for a meaningful attempt (`minAttemptSeconds`). Only transient errors (see
/// `isTransientAIError`) are retried; everything else throws immediately.
///
/// `now`/`sleep` are injectable so the retry policy is unit-testable without a
/// real clock, real network, or real wall-clock delay.
func withAIRetry<T>(
    totalBudget: TimeInterval,
    maxRetries: Int = 2,
    minAttemptSeconds: TimeInterval = 5,
    now: () -> Date = Date.init,
    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    _ attempt: (_ attemptTimeout: TimeInterval) throws -> T
) throws -> T {
    let deadline = now().addingTimeInterval(totalBudget)
    var lastError: Error = AIProviderError.networkError("no attempt made")
    for tryIndex in 0 ... maxRetries {
        let remaining = deadline.timeIntervalSince(now())
        // After the first try, bail if the budget can't fit a meaningful attempt.
        if tryIndex > 0, remaining < minAttemptSeconds { break }
        let attemptTimeout = max(minAttemptSeconds, remaining)
        do {
            return try attempt(attemptTimeout)
        } catch let error as AIProviderError {
            lastError = error
            guard isTransientAIError(error), tryIndex < maxRetries else { throw error }
            // Short backoff, but never sleep past what the budget can spare.
            let spare = deadline.timeIntervalSince(now()) - minAttemptSeconds
            let backoff = min(0.5 * Double(tryIndex + 1), spare)
            if backoff > 0 { sleep(backoff) }
        }
    }
    throw lastError
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
