import Foundation

/// Prints compact (non-pretty-printed) JSON for agent consumption.
/// Agents consume token-efficiently; no whitespace, no sorted keys.
public func printAgentJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    // No outputFormatting — compact by default
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8)!)
}

// MARK: - Agent Error Output

/// Structured error payload for agent mode.
/// Output shape: {"error":{"code":"snake_case_code","message":"Human-readable description"}}
public struct AgentError: Encodable {
    public struct ErrorPayload: Encodable {
        public let code: String
        public let message: String
    }

    public let error: ErrorPayload

    public init(code: String, message: String) {
        error = ErrorPayload(code: code, message: message)
    }

    /// Derive an AgentError from any Swift Error.
    /// - `code`: snake_case case name derived from the error enum case (e.g. `accessDenied` → `access_denied`)
    /// - `message`: `errorDescription` if LocalizedError, otherwise `localizedDescription`
    public static func from(_ error: Error) -> AgentError {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let code = agentErrorCode(for: error)
        return AgentError(code: code, message: message)
    }
}

/// Print a structured JSON error to stdout for agent consumers.
public func printAgentError(_ error: Error) {
    let agentError = AgentError.from(error)
    if let data = try? JSONEncoder().encode(agentError),
       let str = String(data: data, encoding: .utf8)
    {
        print(str)
    }
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
