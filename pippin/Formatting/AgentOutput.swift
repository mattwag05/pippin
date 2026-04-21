import Foundation

/// Schema version for the agent-mode JSON envelope. Bumps on any breaking
/// change to the envelope shape; consumers gate on this field.
public let AGENT_SCHEMA_VERSION = 1

// MARK: - Envelope types

/// Success envelope — wraps the original payload under `data`.
/// Shape: {"v":1,"status":"ok","duration_ms":234,"data":<payload>}
public struct AgentOkEnvelope<T: Encodable>: Encodable {
    public let v: Int
    public let status: String
    public let durationMs: Int
    public let data: T

    enum CodingKeys: String, CodingKey {
        case v, status
        case durationMs = "duration_ms"
        case data
    }

    public init(v: Int, status: String, durationMs: Int, data: T) {
        self.v = v
        self.status = status
        self.durationMs = durationMs
        self.data = data
    }
}

/// Error envelope — wraps the `AgentError.ErrorPayload` under `error`.
/// Shape: {"v":1,"status":"error","duration_ms":12,"error":{"code":"…","message":"…","remediation":{…}?}}
public struct AgentErrorEnvelope: Encodable {
    public let v: Int
    public let status: String
    public let durationMs: Int
    public let error: AgentError.ErrorPayload

    enum CodingKeys: String, CodingKey {
        case v, status
        case durationMs = "duration_ms"
        case error
    }

    public init(v: Int, status: String, durationMs: Int, error: AgentError.ErrorPayload) {
        self.v = v
        self.status = status
        self.durationMs = durationMs
        self.error = error
    }
}

// MARK: - Print helpers

/// Prints compact (non-pretty-printed) JSON for agent consumption, wrapped in
/// envelope v1.
///
/// - Parameters:
///   - value: the original payload (becomes `.data`).
///   - startedAt: wall-clock time when the command began; used to compute
///     `duration_ms`. Defaults to `Date()` (≈0ms) — callers should thread
///     their own `OutputOptions.startedAt` via `output.printAgent(_:)` for
///     accurate timing.
public func printAgentJSON<T: Encodable>(_ value: T, startedAt: Date = Date()) throws {
    let envelope = AgentOkEnvelope(
        v: AGENT_SCHEMA_VERSION,
        status: "ok",
        durationMs: durationMs(from: startedAt),
        data: value
    )
    let encoder = JSONEncoder()
    let data = try encoder.encode(envelope)
    print(String(data: data, encoding: .utf8)!)
}

// MARK: - Agent Error Output

/// Structured error payload for agent mode.
/// Output shape inside envelope:
///   {"code":"snake_case_code","message":"...","remediation":{...}?}
/// The `remediation` field is omitted (not null) when no catalog entry exists
/// for the error's code, so unchanged error shapes remain backward-compatible.
public struct AgentError: Encodable {
    public struct ErrorPayload: Encodable {
        public let code: String
        public let message: String
        public let remediation: Remediation?

        private enum CodingKeys: String, CodingKey {
            case code, message, remediation
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(remediation, forKey: .remediation)
        }
    }

    public let error: ErrorPayload

    public init(code: String, message: String, remediation: Remediation? = nil) {
        error = ErrorPayload(code: code, message: message, remediation: remediation)
    }

    /// Derive an AgentError from any Swift Error.
    /// - `code`: snake_case case name derived from the error enum case (e.g. `accessDenied` → `access_denied`)
    /// - `message`: `errorDescription` if LocalizedError, otherwise `localizedDescription`
    /// - `remediation`: enrichment from `RemediationCatalog`, if the code is registered
    public static func from(_ error: Error) -> AgentError {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let code = agentErrorCode(for: error)
        let remediation = RemediationCatalog.forCode(code)
        return AgentError(code: code, message: message, remediation: remediation)
    }
}

/// Print a structured JSON error to stdout for agent consumers, wrapped in
/// envelope v1.
///
/// - Parameters:
///   - error: the underlying Swift error.
///   - startedAt: wall-clock start time; defaults to `Date()` (duration_ms ≈ 0).
public func printAgentError(_ error: Error, startedAt: Date = Date()) {
    let agentError = AgentError.from(error)
    let envelope = AgentErrorEnvelope(
        v: AGENT_SCHEMA_VERSION,
        status: "error",
        durationMs: durationMs(from: startedAt),
        error: agentError.error
    )
    if let data = try? JSONEncoder().encode(envelope),
       let str = String(data: data, encoding: .utf8)
    {
        print(str)
    }
}

/// Compute elapsed milliseconds from `start` to now, clamped to non-negative.
private func durationMs(from start: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(start) * 1000))
}

/// Derive a snake_case error code from an error's case name.
/// Examples: `scriptFailed("...")` → `"script_failed"`, `accessDenied` → `"access_denied"`
public func agentErrorCode(for error: Error) -> String {
    // String(describing:) on an enum case gives "caseName(assoc)" or just "caseName"
    let description = String(describing: error)
    // Strip associated values
    let caseName = description.components(separatedBy: "(").first ?? description
    // Convert camelCase to snake_case
    return camelToSnakeCase(caseName)
}

private func camelToSnakeCase(_ input: String) -> String {
    var result = ""
    for (index, char) in input.enumerated() {
        if char.isUppercase, index > 0 {
            result.append("_")
        }
        result.append(char.lowercased())
    }
    return result
}
