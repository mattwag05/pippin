import Foundation

/// Minimal typed JSON value used where we need to round-trip arbitrary JSON
/// (MCP tool input schemas, JSON-RPC `params`, generic results). Built for
/// readability, not performance — schemas are small and infrequent.
// swiftformat:disable:next redundantSendable
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(dict) = self else { return nil }
        return dict[key]
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var intValue: Int64? {
        switch self {
        case let .int(value): return value
        case let .double(value):
            // A JSON number larger than Int64 decodes as `.double` (see init),
            // and `Int64(Double)` TRAPS for a non-finite or out-of-range value.
            // An MCP arg like `{"limit": 1e19}` must not crash the child — coerce
            // only when it fits, otherwise treat the arg as absent (nil).
            // Compare with `< Double(Int64.max)`: Int64.max isn't exactly
            // representable as a Double and rounds up to Int64.max + 1.
            guard value.isFinite, value >= Double(Int64.min), value < Double(Int64.max) else { return nil }
            return Int64(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case let .double(value): return value
        case let .int(value): return Double(value) // a whole-number JSON arg (e.g. 1) for a number field
        default: return nil
        }
    }
}
