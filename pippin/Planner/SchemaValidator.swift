import Foundation

// MARK: - SchemaValidator

/// Best-effort validator for LLM-proposed tool arguments against an
/// `MCPTool.inputSchema`. Checks required fields + top-level type tags
/// (`"string"`, `"integer"`, `"boolean"`, `"array"`). Does not recurse into
/// nested `properties` of array items — the MCP tool's `buildArgs` closure
/// will fail downstream if the shape is truly wrong, so this validator
/// exists to catch the common LLM mistakes (missing required field, wrong
/// primitive type) before a subprocess is spawned.
enum SchemaValidator {
    /// Validate `args` against `schema` (an MCPTool.inputSchema JSONValue).
    /// Throws `SchemaValidatorError` on the first problem.
    static func validate(args: JSONValue?, against schema: JSONValue) throws {
        let required = extractRequired(schema)
        let properties = extractProperties(schema)

        let argsObject: [String: JSONValue]
        switch args {
        case let .some(.object(value)):
            argsObject = value
        case .none, .some(.null):
            argsObject = [:]
        default:
            throw SchemaValidatorError.wrongType(
                field: "<root>", expected: "object", got: typeName(of: args)
            )
        }

        for name in required where argsObject[name] == nil {
            throw SchemaValidatorError.missingRequired(name)
        }

        for (name, value) in argsObject {
            guard let propSchema = properties[name] else { continue }
            try checkScalarType(field: name, value: value, schema: propSchema)
        }
    }

    // MARK: - Helpers

    private static func extractRequired(_ schema: JSONValue) -> [String] {
        guard case let .some(.array(values)) = schema["required"] else { return [] }
        return values.compactMap { $0.stringValue }
    }

    private static func extractProperties(_ schema: JSONValue) -> [String: JSONValue] {
        guard case let .some(.object(dict)) = schema["properties"] else { return [:] }
        return dict
    }

    private static func checkScalarType(
        field: String,
        value: JSONValue,
        schema: JSONValue
    ) throws {
        guard let typeTag = schema["type"]?.stringValue else { return }
        let matches: Bool
        switch typeTag {
        case "string": matches = value.stringValue != nil
        case "integer": matches = value.intValue != nil
        case "boolean": matches = value.boolValue != nil
        case "array":
            if case .array = value { matches = true } else { matches = false }
        case "object":
            if case .object = value { matches = true } else { matches = false }
        case "number":
            switch value {
            case .int, .double: matches = true
            default: matches = false
            }
        default:
            matches = true // unknown type tag — accept
        }
        if !matches {
            throw SchemaValidatorError.wrongType(
                field: field, expected: typeTag, got: typeName(of: value)
            )
        }
    }

    private static func typeName(of value: JSONValue?) -> String {
        guard let value else { return "null" }
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}

// MARK: - Errors

enum SchemaValidatorError: LocalizedError, Equatable {
    case missingRequired(String)
    case wrongType(field: String, expected: String, got: String)

    var errorDescription: String? {
        switch self {
        case let .missingRequired(name):
            return "Missing required argument: '\(name)'."
        case let .wrongType(field, expected, got):
            return "Argument '\(field)' must be \(expected), got \(got)."
        }
    }
}
