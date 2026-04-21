import Foundation

/// Idempotent retry helper for `pippin browser` subcommands.
///
/// Re-invokes `operation` up to `retry + 1` times. Stops early when:
/// - `expectField` is `nil` and the operation returned a value, OR
/// - the field at `expectField` (dot-separated path into the encoded payload)
///   is non-empty.
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
    ) throws -> (result: T, attempts: Int) {
        let maxAttempts = max(1, retry + 1)
        let delay = max(0, delayMs)
        var attempt = 0
        var lastResult: T?
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            do {
                let result = try operation()
                if try expectFieldSatisfied(result, path: expectField) {
                    return (result, attempt)
                }
                lastResult = result
                lastError = nil
            } catch {
                lastError = error
                lastResult = nil
            }
            if attempt < maxAttempts, delay > 0 {
                Thread.sleep(forTimeInterval: Double(delay) / 1000.0)
            }
        }

        if let result = lastResult {
            return (result, attempt)
        }
        throw lastError ?? BrowserRetryError.exhausted
    }

    public static func expectFieldSatisfied(_ value: some Encodable, path: String?) throws -> Bool {
        guard let path, !path.isEmpty else { return true }
        let data = try JSONEncoder().encode(value)
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let leaf = walkJSONPath(json, path: path) else { return false }
        return isNonEmpty(leaf)
    }

    public static func walkJSONPath(_ root: Any, path: String) -> Any? {
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

    public static func isNonEmpty(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if let s = value as? String { return !s.isEmpty }
        if let arr = value as? [Any] { return !arr.isEmpty }
        if let dict = value as? [String: Any] { return !dict.isEmpty }
        return true
    }
}

public enum BrowserRetryError: LocalizedError {
    case exhausted
    public var errorDescription: String? {
        "Browser retry exhausted with no successful result"
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
