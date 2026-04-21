import Foundation

/// Idempotent retry helper for `pippin browser` subcommands.
///
/// Re-invokes `operation` up to `retry + 1` times when it returns a value
/// whose `expectField` is empty. Errors thrown by `operation` propagate
/// immediately — retrying "Node not installed" or "session not active" wastes
/// time and obscures the real failure. The `--retry` knob exists for the
/// "page not yet loaded" case (script ran, returned an empty title), not
/// transport failures.
///
/// `--expect-field` is evaluated against the raw payload (PageInfo, SnapshotResult, …),
/// not the agent-mode envelope. So for `browser open`, the path is `title`, not
/// `data.title`.
public enum BrowserRetry {
    public static func run<T: Encodable>(
        retry: Int,
        delayMs: Int,
        expectField: String?,
        operation: () throws -> T
    ) async throws -> (result: T, attempts: Int) {
        let maxAttempts = max(1, retry + 1)
        let delayNs = UInt64(max(0, delayMs)) * 1_000_000
        var attempt = 0
        var lastResult: T!

        while attempt < maxAttempts {
            attempt += 1
            let result = try operation() // throws propagate; retry is only for empty expect-field
            if try expectFieldSatisfied(result, path: expectField) {
                return (result, attempt)
            }
            lastResult = result
            if attempt < maxAttempts, delayNs > 0 {
                try? await Task.sleep(nanoseconds: delayNs)
            }
        }
        return (lastResult, attempt)
    }

    static func expectFieldSatisfied(_ value: some Encodable, path: String?) throws -> Bool {
        guard let path, !path.isEmpty else { return true }
        let data = try JSONEncoder().encode(value)
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let leaf = walkJSONPath(json, path: path) else { return false }
        return isNonEmpty(leaf)
    }

    static func walkJSONPath(_ root: Any, path: String) -> Any? {
        var current: Any? = root
        for token in path.split(separator: ".").map(String.init) {
            guard let node = current else { return nil }
            if let dict = node as? [String: Any] {
                current = dict[token]
            } else if let arr = node as? [Any], let idx = Int(token), idx >= 0, idx < arr.count {
                current = arr[idx]
            } else {
                return nil
            }
        }
        return current
    }

    static func isNonEmpty(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if let s = value as? String { return !s.isEmpty }
        if let arr = value as? [Any] { return !arr.isEmpty }
        if let dict = value as? [String: Any] { return !dict.isEmpty }
        return true
    }
}

/// Encodes `payload` and adds an `_attempts` sibling key. Requires `T` to encode
/// as a JSON object (keyed container) — true for all browser result types.
public struct WithAttempts<T: Encodable>: Encodable {
    public let payload: T
    public let attempts: Int

    public init(payload: T, attempts: Int) {
        self.payload = payload
        self.attempts = attempts
    }

    private enum AttemptsKey: String, CodingKey {
        case attempts = "_attempts"
    }

    public func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: AttemptsKey.self)
        try container.encode(attempts, forKey: .attempts)
    }
}
