import Foundation

/// Prints compact (non-pretty-printed) JSON for agent consumption.
/// Agents consume token-efficiently; no whitespace, no sorted keys.
public func printAgentJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    // No outputFormatting — compact by default
    let data = try encoder.encode(value)
    print(String(data: data, encoding: .utf8)!)
}
